import AVFoundation
import AppKit
import BiliNextCore
import Combine
import QuartzCore
import Testing

@testable import BiliNext

@MainActor
@Test func playbackTicksDoNotInvalidateTheAppShell() {
    let model = AppModel()
    var shellUpdates = 0
    var clockUpdates = 0
    let shell = model.objectWillChange.sink { shellUpdates += 1 }
    let clock = model.playbackClock.objectWillChange.sink { clockUpdates += 1 }
    for tick in 1...40 {
        model.updatePlayback(time: Double(tick) / 4, duration: 0, playing: false, buffering: false)
    }
    #expect(clockUpdates == 40)
    #expect(shellUpdates == 0)
    model.updatePlayback(time: 10, duration: 120, playing: true, buffering: false)
    #expect(shellUpdates == 2)
    #expect(clockUpdates == 40)
    model.updatePlayback(time: .nan, duration: .infinity, playing: false)
    #expect(model.time == 0)
    #expect(model.duration == 0)
    withExtendedLifetime((shell, clock)) {}
}

@MainActor
@Test func danmakuTexturesAndAnimationsSurviveTicksButResynchronizeOnSeek() {
    let surface = DanmakuSurface.Surface(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let comments = [
        Danmaku(id: "scroll", time: 0, mode: 1, text: "渲染测试"),
        Danmaku(id: "top", time: 0, mode: 5, text: "顶部弹幕"),
        Danmaku(id: "later", time: 10, mode: 1, text: "跳转后的弹幕"),
    ]
    surface.items = DanmakuLayout.arrange(comments, viewport: 800, lanes: 6, duration: 8) { _ in 120
    }
    surface.maximumDuration = 8
    surface.running = true
    surface.render(time: 1)
    let scrolling = surface.labels["scroll"]!
    #expect(scrolling.contents != nil)
    #expect(CFGetTypeID(scrolling.contents as CFTypeRef) == CGImage.typeID)
    #expect(!(scrolling is CATextLayer))
    #expect(scrolling.shadowOpacity == 0)
    #expect(scrolling.animation(forKey: "scroll") != nil)
    #expect(surface.labels["top"]?.animation(forKey: "scroll") == nil)
    let position = scrolling.position
    surface.render(time: 1.01)
    #expect(surface.labels["scroll"] === scrolling)
    #expect(scrolling.position == position)
    surface.running = false
    surface.render(time: 2)
    #expect(scrolling.animation(forKey: "scroll") == nil)
    #expect(scrolling.position.x < position.x)
    surface.render(time: 10.5)
    #expect(surface.labels.keys.sorted() == ["later"])
    surface.render(time: 0.5)
    #expect(surface.labels.keys.sorted() == ["scroll", "top"])
}
