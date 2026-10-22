import AppKit
import SwiftUI

/// Records one shortcut for the host application's feedback menu action.
public struct FeedbackShortcutSettings: View {
    @Binding private var shortcut: FeedbackShortcut?
    @StateObject private var recorder = FeedbackShortcutRecorder()

    public init(shortcut: Binding<FeedbackShortcut?>) {
        _shortcut = shortcut
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("反馈快捷键") {
                HStack(spacing: 10) {
                    Text(recorder.isRecording ? "请按下快捷键…" : shortcut?.displayName ?? "未设置")
                        .monospaced()
                        .foregroundStyle(recorder.isRecording ? .primary : .secondary)
                        .accessibilityLabel(
                            recorder.isRecording
                                ? "正在录制快捷键，按 Escape 取消"
                                : "当前快捷键，\(shortcut?.displayName ?? "未设置")")
                    Button(recorder.isRecording ? "取消" : "录制快捷键") {
                        if recorder.isRecording {
                            recorder.cancel()
                        } else {
                            recorder.begin { shortcut = $0 }
                        }
                    }
                    .accessibilityHint("录制时按下包含 Command、Control 或 Option 的组合键")
                    Button("清除") {
                        shortcut = nil
                        recorder.clearMessage()
                    }
                    .disabled(shortcut == nil || recorder.isRecording)
                    .accessibilityLabel("清除反馈快捷键")
                }
            }
            Text("仅在当前应用内生效。请包含 ⌘、⌃ 或 ⌥，按 Esc 取消录制。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(recorder.hasError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .background(FeedbackShortcutWindowReader { recorder.attach(to: $0) })
        .onDisappear { recorder.cancel(showMessage: false) }
    }
}

@MainActor
private final class FeedbackShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?
    @Published private(set) var hasError = false

    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onRecorded: ((FeedbackShortcut) -> Void)?

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        if isRecording { cancel(showMessage: false) }
        self.window = window
    }

    func begin(onRecorded: @escaping (FeedbackShortcut) -> Void) {
        cancel(showMessage: false)
        guard let window, window.isKeyWindow else {
            showError("请先激活设置窗口，再录制快捷键。")
            return
        }
        self.onRecorded = onRecorded
        clearMessage()
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard self.window?.isKeyWindow == true,
                event.window == nil || event.window === self.window
            else {
                self.cancel()
                return event
            }
            self.receive(event)
            // Consume every key while recording, including conflicting menu equivalents.
            return nil
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancel() }
            })
        observers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancel() }
            })
    }

    func cancel(showMessage: Bool = true) {
        let wasRecording = isRecording
        removeEventHandlers()
        onRecorded = nil
        isRecording = false
        if showMessage && wasRecording {
            message = "已取消录制。"
            hasError = false
        }
    }

    func clearMessage() {
        message = nil
        hasError = false
    }

    private func receive(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
            return
        }
        guard !event.isARepeat else { return }
        let candidate = FeedbackShortcut(
            key: event.charactersIgnoringModifiers ?? "",
            modifiersRawValue: event.modifierFlags.rawValue)
        guard candidate.isValid else {
            showError("请使用字母、数字或符号，并至少搭配 ⌘、⌃、⌥ 中的一个。")
            return
        }
        if let menu = NSApp.mainMenu,
            let conflict = candidate.conflictingMenuItem(in: Self.menuItems(in: menu))
        {
            showError("\(candidate.displayName) 已用于“\(conflict.path)”，请选择其他快捷键。")
            return
        }
        let completion = onRecorded
        cancel(showMessage: false)
        completion?(candidate)
        message = "已设置为 \(candidate.displayName)。"
        hasError = false
    }

    private func showError(_ message: String) {
        self.message = message
        hasError = true
    }

    private static func menuItems(in menu: NSMenu, parents: [String] = [])
        -> [FeedbackShortcutMenuItem]
    {
        menu.items.flatMap { item -> [FeedbackShortcutMenuItem] in
            let path = parents + (item.title.isEmpty ? [] : [item.title])
            var result: [FeedbackShortcutMenuItem] = []
            if !item.keyEquivalent.isEmpty {
                result.append(
                    FeedbackShortcutMenuItem(
                        title: item.title, path: path.joined(separator: " → "),
                        key: item.keyEquivalent,
                        modifiersRawValue: item.keyEquivalentModifierMask.rawValue))
            }
            if let submenu = item.submenu {
                result += menuItems(in: submenu, parents: path)
            }
            return result
        }
    }

    private func removeEventHandlers() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private struct FeedbackShortcutWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    final class WindowView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Removing a SwiftUI host can happen during a view update. Defer any
            // recorder cancellation so it never publishes in that update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWindowChange?(self.window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
