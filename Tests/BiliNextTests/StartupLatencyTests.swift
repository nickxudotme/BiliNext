import AppKit
import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

/// Opt-in latency check: times each stage from requesting a video to its first played frame,
/// through the real APIs and libmpv in a window. Read-only and never reports watch history.
///
///     BILINEXT_STARTUP_TEST=1 swift test --filter playbackStartupLatency
///
/// `BILINEXT_STARTUP_BVID` picks the video; `BILINEXT_STARTUP_LOGIN=1` (Debug) uses the
/// development session for logged-in qualities; `BILINEXT_STARTUP_MPV_OPTIONS=a=b,c=d`
/// overrides mpv properties; `BILINEXT_STARTUP_MPV_LOG=/path` writes mpv's verbose log.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_STARTUP_TEST"] == "1"))
func playbackStartupLatency() async throws {
    _ = NSApplication.shared
    let environment = ProcessInfo.processInfo.environment
    let bvid = environment["BILINEXT_STARTUP_BVID"] ?? "BV1GJ411x7h7"
    let overrides = (environment["BILINEXT_STARTUP_MPV_OPTIONS"] ?? "")
        .split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    #if DEBUG
        let api =
            environment["BILINEXT_STARTUP_LOGIN"] == "1"
            ? BilibiliAPI(credentialStorage: .developmentFile) : BilibiliAPI(restoreSession: false)
    #else
        let api = BilibiliAPI(restoreSession: false)
    #endif
    let clock = ContinuousClock()
    let start = clock.now
    func stamp(_ label: String) { print("STARTUP", label, clock.now - start) }

    try await api.ensureBrowserIdentifier()
    stamp("buvid")
    let detail = try await api.videoPage(bvid)
    stamp("videoPage")
    let cid = try #require(detail.pages.first?.cid)
    let playback = try await api.playback(bvid: bvid, cid: cid, quality: 80)
    stamp("playurl \(playback.quality) \(playback.videoStream?.codec ?? "mp4")")
    for url in (playback.videoStream?.urls ?? []) + (playback.audioStream?.urls ?? []) {
        print("STARTUP mirror", url.host ?? "", CDNPreference.rank(url))
    }

    let core = try MPVPlayer()
    for (key, value) in overrides { core.set(key, value) }
    if let file = environment["BILINEXT_STARTUP_MPV_LOG"] {
        core.set("log-file", file)
        core.set("msg-level", "all=v")
    }
    core.muted = true
    let surface = try #require(MPVSurface.Surface(player: core))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = surface
    window.orderFront(nil)
    defer {
        core.stop()
        surface.releaseRenderer()
        window.orderOut(nil)
    }
    var loadedAt: Duration?
    var playingAt: Duration?
    core.onUpdate = { time, _, playing, _ in
        if core.loaded && loadedAt == nil { loadedAt = clock.now - start }
        if playing && time > 0.05 && playingAt == nil { playingAt = clock.now - start }
    }
    let issued = clock.now - start
    try core.load(playback, position: 0, autoplay: true)
    for _ in 0..<300 where playingAt == nil { try await Task.sleep(for: .milliseconds(50)) }
    print("STARTUP load issued", issued)
    print("STARTUP mpv loaded", loadedAt.map { "\($0)" } ?? "never")
    print("STARTUP playing", playingAt.map { "\($0)" } ?? "never")
    #expect(playingAt != nil, "playback did not start within 15 seconds")
}
