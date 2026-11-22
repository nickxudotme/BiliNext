import AppKit
import BiliNextCore
import Testing

@testable import BiliNext

@MainActor
@Test func inactivePlaybackHostDefersResizingUntilActivation() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
        sessionStore: SessionStore(directory: directory), managesPlaybackTabs: false,
        api: BilibiliAPI(restoreSession: false))
    var configuration = PlaybackTabHost.Configuration(
        navigationOverlayVisible: false, miniPlayer: false, windowPinned: false, isActive: true)
    let host = PlaybackTabHost.Host(model: model, configuration: configuration, onExitCommand: {})
    let content = try #require(host.subviews.first)
    host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
    host.layout()
    #expect(content.frame == host.bounds)
    let retainedFrame = content.frame

    configuration.isActive = false
    host.update(model: model, configuration: configuration, onExitCommand: {})
    #expect(host.isHidden)
    // A sidebar transition offers intermediate widths to every retained tab.
    for width in stride(from: 1420, through: 1620, by: 20) {
        host.setFrameSize(NSSize(width: width, height: 900))
        host.layout()
        #expect(content.frame == retainedFrame)
    }

    configuration.isActive = true
    host.update(model: model, configuration: configuration, onExitCommand: {})
    // Activation must apply the latest viewport before the page is shown,
    // preserving the hosting view (and its scroll/panel/player state).
    #expect(!host.isHidden)
    #expect(host.subviews.first === content)
    #expect(content.frame == host.bounds)
    host.setFrameSize(NSSize(width: 1500, height: 900))
    host.layout()
    #expect(content.frame == host.bounds)
}
