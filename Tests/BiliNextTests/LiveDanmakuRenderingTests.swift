import AppKit
import BiliNextCore
import QuartzCore
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Test func liveDanmakuRetainsTexturesAcrossArrivalAndFreezesWhenPaused() throws {
    let surface = DanmakuSurface.Surface(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    var timeline = LiveDanmakuTimeline()
    surface.maximumDuration = 8
    surface.fixed = false
    surface.running = true
    surface.items = timeline.append(
        [Danmaku(id: "first", time: 0, mode: 1, text: "第一条")],
        at: 0, viewport: 800, lanes: 4, duration: 8
    ) { _ in 120 }
    surface.render(time: 0)
    let first = try #require(surface.labels["first"])
    let position = first.position
    surface.items = timeline.append(
        [Danmaku(id: "second", time: 0.01, mode: 1, text: "实时到达")],
        at: 0.01, viewport: 800, lanes: 4, duration: 8
    ) { _ in 120 }
    surface.render(time: 0.01)
    #expect(surface.labels.count == 2)
    #expect(surface.labels["first"] === first)
    #expect(first.position == position)
    #expect(first.animation(forKey: "scroll") != nil)
    surface.running = false
    surface.render(time: 1)
    let paused = first.position
    #expect(first.animation(forKey: "scroll") == nil)
    surface.render(time: 1)
    #expect(first.position == paused)
    surface.running = true
    surface.render(time: 1)
    #expect(first.animation(forKey: "scroll") != nil)
    surface.render(time: 9)
    #expect(surface.labels.isEmpty)
}

@MainActor
@Test func liveOverlayAdmitsNewMessagesWithoutReplayingPausedMessages() async throws {
    _ = NSApplication.shared
    let configuration = LiveDanmakuSurface.Configuration(
        size: CGSize(width: 800, height: 500), font: 20, area: 0.5, speed: 1, blocked: "屏蔽")
    func overlay(_ messages: [LiveChatMessage], playing: Bool = true) -> LiveDanmakuSurface {
        LiveDanmakuSurface(
            messages: messages, playing: playing, enabled: true, opacity: 0.85,
            configuration: configuration)
    }
    let host = NSHostingView(rootView: overlay([]))
    host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func find(_ view: NSView) -> DanmakuSurface.Surface? {
        if let surface = view as? DanmakuSurface.Surface { return surface }
        return view.subviews.compactMap(find).first
    }
    let surface = try #require(find(host))
    let first = LiveChatMessage(
        message: "新消息", user: "用户", userID: 1,
        time: Date(), color: 0xffffff)
    host.rootView = overlay([first])
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(surface.items.map(\.id) == [first.id])
    let paused = LiveChatMessage(
        message: "暂停期间", user: "用户", userID: 1,
        time: Date(), color: 0xffffff)
    host.rootView = overlay([first, paused], playing: false)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!surface.running)
    host.rootView = overlay([first, paused])
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(surface.running)
    #expect(surface.items.map(\.id) == [first.id])
}
