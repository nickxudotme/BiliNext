import AppKit
import Testing

@testable import BiliNext

@MainActor
@Test func fullscreenTitlebarRestoresButtonsWithHiddenSidebar() throws {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    let chrome = WindowChrome.ChromeView()
    window.contentView = chrome
    defer { window.contentView = nil }
    chrome.setButtonsVisible(false)
    let close = try #require(window.standardWindowButton(.closeButton))
    // Start from the completed hidden state without depending on AppKit animation timing.
    close.isHidden = true
    close.alphaValue = 0

    // Simulate the fullscreen notification while the sidebar remains collapsed.
    chrome.configure(fullScreen: true)
    chrome.setButtonsVisible(false)
    #expect(!close.isHidden)
}
