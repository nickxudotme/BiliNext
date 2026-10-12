import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func mpvStartsPausedAndKeepsIndependentVolumeAndSpeed() throws {
    let first = try MPVPlayer(videoOutput: "null")
    let second = try MPVPlayer(videoOutput: "null")
    first.volume = 0
    first.speed = 1.5
    second.volume = 0.5
    #expect(first.volume == 0)
    #expect(first.number("speed") == 1.5)
    #expect(second.volume == 0.5)
    #expect(first.flag("pause") && second.flag("pause"))
    #expect(first.flag("cache"))
}

@MainActor
@Test func mpvBufferMarginTracksRateWithinMemoryLimit() throws {
    let core = try MPVPlayer(videoOutput: "null")
    #expect(core.flag("options/cache-pause-initial"))
    core.speed = 3
    #expect(core.number("options/cache-secs") == 180)
    #expect(core.number("options/cache-pause-wait") == 9)
    #expect(core.number("options/demuxer-max-bytes") == 256 * 1024 * 1024)
    core.speed = 0.5
    #expect(core.number("options/cache-secs") == 60)
    #expect(core.number("options/cache-pause-wait") == 3)
    #expect(core.number("options/demuxer-max-bytes") == 128 * 1024 * 1024)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func mpvTripleSpeedMaintainsForwardBuffer() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    let detail = try await api.detail("BV1DApx61EcR")
    let page = try #require(detail.pages.first)
    let source = try await api.playback(bvid: detail.video.bvid, cid: page.cid, quality: 80)
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.speed = 3
    defer { core.stop() }
    try core.load(source, position: 120, autoplay: true)
    var rebuffered = 0
    var began = false
    for _ in 0..<160 {
        try await Task.sleep(for: .milliseconds(250))
        if core.time > 121 { began = true }
        if began && core.flag("paused-for-cache") { rebuffered += 1 }
        if core.time >= 150 || core.failure != nil { break }
    }
    #expect(core.failure == nil)
    #expect(core.time >= 150)
    #expect(core.number("speed") == 3)
    #expect(rebuffered == 0)
    print("3x network playback: time=\(core.time), cache=\(core.number("demuxer-cache-duration"))s, download=\(core.number("cache-speed"))B/s, buffering-samples=\(rebuffered)")
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func mpvDirectDASHPlaysSeeksSwitchesAndRetainsTabs() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    let detail = try await api.detail("BV1DApx61EcR")
    let page = try #require(detail.pages.first)
    let source = try await api.playback(bvid: detail.video.bvid, cid: page.cid, quality: 80)
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    defer { core.stop() }
    try core.load(source, position: 0, autoplay: true)
    func wait(_ target: Double) async throws {
        for _ in 0..<300 {
            if core.time >= target || core.failure != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(core.failure == nil)
        #expect(core.loaded)
        #expect(core.time >= target)
    }
    try await wait(45)
    #expect(core.number("audio-params/channel-count") > 0)
    #expect(core.number("video-params/w") > 0)
    print(
        "MPV: \(core.text("mpv-version")); decoder=\(core.text("hwdec-current")); video=\(core.number("video-params/w"))x\(core.number("video-params/h")); audio=\(core.number("audio-params/channel-count"))"
    )
    core.seek(120)
    core.speed = 2
    try await wait(123)
    core.pause()
    let position = core.time
    try await Task.sleep(for: .milliseconds(750))
    #expect(abs(core.time - position) < 0.2)
    let second = try MPVPlayer(videoOutput: "null")
    second.muted = true
    defer { second.stop() }
    try second.load(source, position: 10, autoplay: true)
    try await Task.sleep(for: .seconds(3))
    #expect(abs(core.time - position) < 0.2)
    #expect(second.time > 10)
    let lower = try await api.playback(bvid: detail.video.bvid, cid: page.cid, quality: 64)
    try core.load(lower, position: position, autoplay: true)
    try await wait(position + 2)
    #expect(core.muted)
}
