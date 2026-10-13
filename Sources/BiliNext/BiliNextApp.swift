import AppKit
import SwiftUI

@main
struct BiliNextApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    var body: some Scene {
        Window("BiliNext", id: "main") {
            ShellView(model: model)
                .frame(minWidth: 940, minHeight: 600)
                .task { await model.start() }
                .onAppear {
                    terminationDelegate.model = model
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
            CommandGroup(after: .newItem) {
                Button("下载管理") { model.downloadsPresented = true }.keyboardShortcut("j")
                Button("搜索视频") { model.navigate("搜索") }.keyboardShortcut("l")
                Button("关闭视频标签") { if let id = model.selected { model.close(id) } }
                    .keyboardShortcut("w")
                    .disabled(model.selected == nil)
                Button("恢复关闭的标签") { model.undoClose() }.keyboardShortcut(
                    "t", modifiers: [.command, .shift]
                )
                .disabled(model.closed.isEmpty)
            }
        }
    }
}
