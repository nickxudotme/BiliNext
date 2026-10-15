import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
struct OnlineViewerPollerTests {
    @Test func eligibilityUsesOrdinaryVideoAndCurrentPartOnly() throws {
        let video = Video(bvid: "BV1111111111", title: "普通视频")
        let first = try #require(OnlineViewerPoller.Target(video: video, cid: 42))
        let second = try #require(OnlineViewerPoller.Target(video: video, cid: 43))
        #expect(first != second)
        #expect(OnlineViewerPoller.Target(video: video, cid: 42, isActive: false) == nil)
        #expect(OnlineViewerPoller.Target(video: video, cid: nil) == nil)
        #expect(OnlineViewerPoller.Target(video: video, cid: 0) == nil)
        #expect(OnlineViewerPoller.Target(video: nil, cid: 42) == nil)
        for bvid in ["live:42", "space:7", "ep123"] {
            #expect(OnlineViewerPoller.Target(video: Video(bvid: bvid, title: ""), cid: 42) == nil)
        }
        #expect(
            OnlineViewerPoller.Target(
                video: Video(bvid: video.bvid, title: "番剧", episodeID: 7), cid: 42) == nil)
    }

    @Test func changingPartDiscardsLateResponseAndClearsOnCancellation() async throws {
        let poller = OnlineViewerPoller()
        let first = try target(cid: 42)
        let second = try target(cid: 43)
        var response: CheckedContinuation<OnlineViewerCount?, Never>?
        let old = Task {
            await poller.poll(first) { _ in await withCheckedContinuation { response = $0 } }
        }
        try await eventually { response != nil }
        let current = Task { await poller.poll(second) { _ in try count("22") } }
        try await eventually { poller.value(for: second)?.total == "22" }
        #expect(poller.value(for: first) == nil)
        response?.resume(returning: try count("11"))
        await old.value
        #expect(poller.target == second && poller.count?.total == "22")
        current.cancel()
        await current.value
        #expect(poller.target == nil && poller.count == nil)
    }

    @Test func hidingAndResumingSameVideoRejectsPreviousGeneration() async throws {
        let poller = OnlineViewerPoller()
        let target = try target()
        var response: CheckedContinuation<OnlineViewerCount?, Never>?
        let old = Task {
            await poller.poll(target) { _ in await withCheckedContinuation { response = $0 } }
        }
        try await eventually { response != nil }
        poller.stop()
        #expect(poller.value(for: target) == nil)
        let resumed = Task { await poller.poll(target) { _ in try count("22") } }
        try await eventually { poller.count?.total == "22" }
        response?.resume(returning: try count("11"))
        await old.value
        #expect(poller.count?.total == "22")
        resumed.cancel()
        await resumed.value
    }

    @Test func transientFailureWaitsBeforeRecoveringWithoutFakeZero() async throws {
        let poller = OnlineViewerPoller()
        let target = try target()
        var calls = 0
        var delay: CheckedContinuation<Void, Never>?
        let task = Task {
            await poller.poll(
                target,
                load: { _ in
                    calls += 1
                    if calls == 1 { throw APIError(code: -403, message: "fixture") }
                    return try count("22")
                },
                wait: {
                    if calls == 1 {
                        await withCheckedContinuation { delay = $0 }
                    } else {
                        try await Task.sleep(for: .seconds(30))
                    }
                })
        }
        try await eventually { delay != nil }
        #expect(calls == 1 && poller.count == nil)
        delay?.resume()
        try await eventually { poller.count?.total == "22" }
        #expect(calls == 2)
        task.cancel()
        await task.value
    }

    @Test func cancelledLoadNeverPublishesOrRetries() async throws {
        let poller = OnlineViewerPoller()
        let target = try target()
        var response: CheckedContinuation<OnlineViewerCount?, Never>?
        var calls = 0
        let task = Task {
            await poller.poll(target) { _ in
                calls += 1
                return await withCheckedContinuation { response = $0 }
            }
        }
        try await eventually { response != nil }
        task.cancel()
        response?.resume(returning: try count("11"))
        await task.value
        #expect(poller.count == nil && poller.target == nil && calls == 1)
    }

    private func target(cid: Int64 = 42) throws -> OnlineViewerPoller.Target {
        try #require(
            OnlineViewerPoller.Target(video: Video(bvid: "BV1111111111", title: ""), cid: cid))
    }

    private func count(_ text: String) throws -> OnlineViewerCount {
        try #require(OnlineViewerCount(data: ["total": text]))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
