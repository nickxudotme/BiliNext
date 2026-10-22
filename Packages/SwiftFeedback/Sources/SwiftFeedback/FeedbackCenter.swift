import AppKit
import SwiftUI

/// Owns the developer-only feedback session. Hosts decide when to enable it.
@MainActor
public final class FeedbackCenter: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = FeedbackCenter()
    @Published public var shortcut: FeedbackShortcut? {
        didSet {
            let data = shortcut.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "SwiftFeedback.shortcut")
        }
    }
    @Published public private(set) var isCapturing = false
    public var reportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SwiftFeedback")
            .appendingPathComponent("Feedback")
    }
    private var contextProvider: () -> [String: String] = { [:] }
    private weak var hostWindow: NSWindow?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var editor: NSWindow?
    private var eventMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []

    public override init() {
        if let data = UserDefaults.standard.data(forKey: "SwiftFeedback.shortcut"),
            let value = try? JSONDecoder().decode(FeedbackShortcut.self, from: data), value.isValid
        {
            shortcut = value
        }
        super.init()
    }

    public func configure(contextProvider: @escaping () -> [String: String]) {
        self.contextProvider = contextProvider
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .keyDown,
        ]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53, self?.session?.phase == .recording {
                self?.session?.stopRecording()
                return nil
            }
            self?.recordInteraction(event)
            return event
        }
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
        ] {
            notificationObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated {
                        guard !(window.identifier?.rawValue.hasPrefix("SwiftFeedback.") ?? false)
                        else { return }
                        if window === self?.sourceWindow,
                            name == NSWindow.willCloseNotification
                                || name == NSWindow.didMiniaturizeNotification
                        {
                            self?.dismiss(restoreFocus: false)
                            return
                        }
                        if window === self?.sourceWindow, self?.session != nil,
                            name == NSWindow.didResizeNotification,
                            self?.session?.phase != .recording
                        {
                            DispatchQueue.main.async { [weak self, weak window] in
                                guard let self, let window, let session = self.session else {
                                    return
                                }
                                self.editor?.setFrame(window.frame, display: true)
                                session.windowResized()
                            }
                        }
                        FeedbackRecorder.shared.record(
                            name.rawValue, fields: ["window": String(window.windowNumber)])
                    }
                })
        }
        FeedbackRecorder.shared.record("feedback.enabled")
    }

    /// An optional host-supplied clarification service; nil saves directly without a question.
    public var questionProvider: FeedbackQuestionProvider?
    @Published public private(set) var isPresented = false
    private var session: FeedbackSession?
    private var recordingBar: NSWindow?

    public func present() {
        if let session {
            if session.phase != .recording { editor?.makeKeyAndOrderFront(nil) }
            return
        }
        guard let window = NSApp.keyWindow ?? hostWindow ?? NSApp.mainWindow else { return }
        sourceWindow = window
        sourceResponder = window.firstResponder
        FeedbackRecorder.shared.record(
            "feedback.open", fields: ["window": String(window.windowNumber)])
        let session = FeedbackSession(
            window: window, directory: reportDirectory,
            contextProvider: contextProvider, questionProvider: questionProvider)
        self.session = session
        session.captureStateChanged = { [weak self] active in self?.isCapturing = active }
        session.close = { [weak self] in self?.dismiss() }
        session.presentationChanged = { [weak self] in self?.updatePresentation() }
        let panel = FeedbackOverlayPanel(
            contentRect: window.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.appearance = window.effectiveAppearance
        panel.title = "界面反馈"
        panel.identifier = NSUserInterfaceItemIdentifier("SwiftFeedback.overlay")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FeedbackEditor(session: session))
        panel.delegate = self
        editor = panel
        isPresented = true
        window.addChildWindow(panel, ordered: .above)
        panel.setFrame(window.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    public func dismiss(restoreFocus: Bool = true) {
        session?.cancel()
        session = nil
        isPresented = false
        isCapturing = false
        if let recordingBar {
            sourceWindow?.removeChildWindow(recordingBar)
            recordingBar.close()
            self.recordingBar = nil
        }
        if let editor {
            self.editor = nil
            sourceWindow?.removeChildWindow(editor)
            editor.close()
        }
        if restoreFocus, let sourceWindow, sourceWindow.isVisible {
            sourceWindow.makeKeyAndOrderFront(nil)
            if let sourceResponder { sourceWindow.makeFirstResponder(sourceResponder) }
        }
    }

    private func updatePresentation() {
        guard let session else { return }
        if session.phase == .recording {
            editor?.orderOut(nil)
            guard let sourceWindow else { return }
            let panel = FeedbackRecordingPanel(
                contentRect: CGRect(x: 0, y: 0, width: 280, height: 60),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.appearance = sourceWindow.effectiveAppearance
            panel.title = "操作录制"
            panel.identifier = NSUserInterfaceItemIdentifier("SwiftFeedback.recording")
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: FeedbackRecordingBar(session: session))
            let frame = sourceWindow.frame
            panel.setFrameOrigin(CGPoint(x: frame.midX - 140, y: frame.minY + 24))
            recordingBar = panel
            sourceWindow.addChildWindow(panel, ordered: .above)
            sourceWindow.makeKeyAndOrderFront(nil)
            panel.orderFront(nil)
        } else {
            if let recordingBar {
                sourceWindow?.removeChildWindow(recordingBar)
                recordingBar.close()
                self.recordingBar = nil
            }
            editor?.makeKeyAndOrderFront(nil)
        }
    }

    public func openReports() {
        try? FileManager.default.createDirectory(
            at: reportDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(reportDirectory)
    }

    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === editor else { return }
        dismiss()
    }

    private func recordInteraction(_ event: NSEvent) {
        guard let window = event.window,
            !(window.identifier?.rawValue.hasPrefix("SwiftFeedback.") ?? false)
        else { return }
        var fields = ["window": String(window.windowNumber)]
        if event.type == .keyDown {
            // Never retain typing from editors, including secure text fields.
            guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField)
            else { return }
            fields["keyCode"] = String(event.keyCode)
            fields["modifiers"] = String(
                event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
            FeedbackRecorder.shared.record("ui.key", fields: fields)
        } else {
            let point = CGPoint(
                x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
            fields["x"] = String(Double(point.x))
            fields["y"] = String(Double(point.y))
            let targets = FeedbackTargetRegistry.shared.snapshot(in: window)
            if let target = FeedbackTargetSnapshot.hitTest(point, in: targets) {
                fields["target"] = target.semanticID
            }
            FeedbackRecorder.shared.record("ui.click", fields: fields)
        }
    }

    fileprivate func attach(_ window: NSWindow?) { if let window { hostWindow = window } }
}

public struct FeedbackWindowReader: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { Reader() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Reader: NSView {
        override func viewDidMoveToWindow() { FeedbackCenter.shared.attach(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

private final class FeedbackOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { FeedbackCenter.shared.sessionEscape() }
}

private final class FeedbackRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension FeedbackCenter {
    fileprivate func sessionEscape() { session?.escape() }
}
