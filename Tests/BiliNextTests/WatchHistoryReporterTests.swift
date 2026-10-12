import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_HISTORY_TEST"] == "1"))
func actualPlaybackAppearsInAccountHistory() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    _ = try await api.profile()
    // Resume the video already watched in this session rather than fabricate a history record.
    let bvid = "BV11obW6pE9h"
    let detail = try await api.detail(bvid)
    let page = try #require(detail.pages.first)
    let playback = try await api.playback(bvid: bvid, cid: page.cid, quality: 80)
    var failures: [String] = []
    let reporter = WatchHistoryReporter(
        send: {
            try await api.reportWatchProgress(bvid: $0.bvid, cid: $0.cid, position: $0.position)
        }, onError: { failures.append($0.localizedDescription) })
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.onUpdate = { time, _, playing, buffering in
        reporter.update(
            bvid: bvid, cid: page.cid, position: time, playing: playing, buffering: buffering)
    }
    defer { core.stop() }
    try core.load(playback, position: 1200, autoplay: true)
    for _ in 0..<120 {
        try await Task.sleep(for: .milliseconds(250))
        if core.time >= 1205 || core.failure != nil { break }
    }
    #expect(core.failure == nil)
    #expect(core.time >= 1205)
    core.pause()
    reporter.update(
        bvid: bvid, cid: page.cid, position: core.time, playing: false, buffering: false)
    await reporter.waitForPendingReports()
    #expect(failures.isEmpty)
    var recorded: Video?
    for _ in 0..<5 {
        let history = try await api.watchHistory(cursor: nil)
        recorded = history.videos.first { $0.bvid == bvid && $0.historyCID == page.cid }
        if (recorded?.progress ?? 0) >= 1205 { break }
        try await Task.sleep(for: .seconds(1))
    }
    #expect((recorded?.progress ?? 0) >= 1205)
    print(
        "Account history verified: \(bvid), progress=\(recorded?.progress ?? -1), cid=\(page.cid)")
}

@MainActor
@Test func watchHistoryThrottlesByWallTimeAndFlushesPauseInOrder() async {
    var sent: [WatchHistoryReporter.Progress] = []
    let reporter = WatchHistoryReporter(
        send: { sent.append($0) }, onError: { _ in Issue.record("Unexpected error") })
    let start = Date(timeIntervalSince1970: 100)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 120, playing: false, buffering: false, now: start)
    reporter.flush(now: start)
    await reporter.waitForPendingReports()
    #expect(sent.isEmpty)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 121, playing: true, buffering: false, now: start)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 150, playing: true, buffering: false,
        now: start.addingTimeInterval(10))
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 165, playing: true, buffering: false,
        now: start.addingTimeInterval(15))
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 167, playing: false, buffering: false,
        now: start.addingTimeInterval(16))
    reporter.flush()
    await reporter.waitForPendingReports()
    #expect(sent.map(\.position) == [121, 165, 167])
}

@MainActor
@Test func watchHistoryFlushesOldPartAndIgnoresBufferingAndInvalidTime() async {
    var sent: [WatchHistoryReporter.Progress] = []
    let reporter = WatchHistoryReporter(
        send: { sent.append($0) }, onError: { _ in Issue.record("Unexpected error") })
    let start = Date(timeIntervalSince1970: 100)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 10, playing: true, buffering: true, now: start)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: .nan, playing: true, buffering: false, now: start)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 11, playing: true, buffering: false, now: start)
    reporter.update(
        bvid: "BVfirst", cid: 1, position: 12, playing: true, buffering: false,
        now: start.addingTimeInterval(1))
    reporter.update(
        bvid: "BVfirst", cid: 2, position: 1, playing: true, buffering: false,
        now: start.addingTimeInterval(2))
    await reporter.waitForPendingReports()
    #expect(sent.map(\.cid) == [1, 1, 2])
    #expect(sent.map(\.position) == [11, 12, 1])
}
