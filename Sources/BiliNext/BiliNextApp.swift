import AppKit
import SwiftUI

#if DEBUG
    import SwiftFeedback
#endif

@main
struct BiliNextApp: App {
    @AppStorage(Preferences.appearance) private var appearance = AppAppearance.system.rawValue
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    var body: some Scene {
        Window("BiliNext", id: "main") {
            ShellView(model: model)
                .onChange(of: appearance, initial: true) { _, value in
                    (AppAppearance(rawValue: value) ?? .system).apply()
                }
                .tint(GlassTheme.accent)
                .frame(
                    minWidth: model.miniPlayer ? 320 : 940, minHeight: model.miniPlayer ? 180 : 600
                )
                .task { await model.start() }
                .onAppear {
                    terminationDelegate.model = model
                    #if DEBUG
                        DevelopmentFeedback.configure(model: model)
                    #endif
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in model.saveSession() }
        }
        .defaultSize(width: 1220, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 BiliNext") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: AppBuildInfo.credits])
                }
            }
            #if DEBUG
                DevelopmentFeedbackCommands()
            #endif
            CommandGroup(after: .newItem) {
                Button("下载管理") { model.downloadsPresented = true }.keyboardShortcut("j")
                Button("搜索视频") { model.navigate(.search) }.keyboardShortcut("l")
                Button("关闭视频标签") { if let id = model.selected { model.close(id) } }
                    .keyboardShortcut("w")
                    .disabled(model.selected == nil)
                Button("恢复关闭的标签") { model.undoClose() }.keyboardShortcut(
                    "t", modifiers: [.command, .shift]
                )
                .disabled(model.closed.isEmpty)
            }
            CommandMenu("标签") {
                Button("下一个标签") { model.cycleTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("上一个标签") { model.cycleTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                ForEach(1..<10) { number in
                    Button(number == 9 ? "最后一个标签" : "第 \(number) 个标签") {
                        model.activateTab(number: number)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button(model.windowPinned ? "取消置顶" : "窗口置顶") { model.toggleWindowPin() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button(model.miniPlayer ? "退出小窗" : "小窗播放") { model.toggleMiniPlayer() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .disabled(!model.miniPlayer && model.selected == nil)
            }
            CommandGroup(before: .sidebar) {
                Button(model.sidebarPinned ? "隐藏侧栏" : "固定侧栏") {
                    model.sidebarPinned.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
        Settings {
            SettingsView().tint(GlassTheme.accent)
        }
    }
}
