import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func historyOutboxPersistsLatestProgressAfterFailureAndRecovers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = directory.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    var failures = 0
    let failed = WatchHistoryOutbox(
        store: store, automatic: false, activeAccount: { 7 },
        send: { _ in throw URLError(.notConnectedToInternet) }, onError: { _ in failures += 1 })
    failed.enqueue(.init(bvid: "BVexample", cid: 1, position: 10), accountID: 7, now: now)
    await failed.sendReady(now: now)
    #expect(failures == 1)
    failed.enqueue(.init(bvid: "BVexample", cid: 1, position: 3), accountID: 7)
    var sent: [Double] = []
    let restored = WatchHistoryOutbox(
        store: store, automatic: false, activeAccount: { 7 },
        send: { sent.append($0.progress.position) })
    #expect(restored.entries.count == 1)
    await restored.sendReady(now: now.addingTimeInterval(300))
    #expect(sent == [3])
    #expect(restored.entries.isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@MainActor
@Test func historyOutboxIsolatesAccountsAndDoesNotRemoveNewerInflightSnapshot() async throws {
    var account: Int64? = 7
    var sent: [WatchHistoryOutbox.Entry] = []
    var continuation: CheckedContinuation<Void, Never>?
    let box = WatchHistoryOutbox(
        store: nil, automatic: false, activeAccount: { account },
        send: { entry in
            sent.append(entry)
            if entry.progress.position == 10 { await withCheckedContinuation { continuation = $0 } }
        })
    box.enqueue(.init(bvid: "BVexample", cid: 1, position: 10), accountID: 7)
    box.enqueue(.init(bvid: "BVother", cid: 2, position: 20), accountID: 8)
    let first = Task { await box.sendReady() }
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    let resume = try #require(continuation)
    box.enqueue(.init(bvid: "BVexample", cid: 1, position: 5), accountID: 7)
    resume.resume()
    await first.value
    #expect(box.entries.contains(where: { $0.progress.position == 5 }))
    await box.sendReady()
    #expect(sent.map(\.accountID) == [7, 7])
    #expect(sent.map { $0.progress.position } == [10, 5])
    account = 8
    box.accountChanged()
    await box.sendReady()
    #expect(sent.map(\.accountID) == [7, 7, 8])
    #expect(box.entries.isEmpty)
}

@MainActor
@Test func historyOutboxRejectsStaleCapacityAndInvalidProgress() {
    let now = Date()
    let box = WatchHistoryOutbox(
        store: nil, capacity: 2, lifetime: 60, automatic: false,
        activeAccount: { nil }, send: { _ in Issue.record("Logged out") })
    box.enqueue(
        .init(bvid: "old", cid: 1, position: 1), accountID: 1, now: now.addingTimeInterval(-100))
    box.enqueue(.init(bvid: "one", cid: 1, position: 1), accountID: 1, now: now)
    box.enqueue(.init(bvid: "two", cid: 2, position: 2), accountID: 1, now: now)
    box.enqueue(.init(bvid: "three", cid: 3, position: 3), accountID: 1, now: now)
    box.enqueue(.init(bvid: "invalid", cid: 4, position: .nan), accountID: 1, now: now)
    #expect(box.entries.map { $0.progress.bvid } == ["two", "three"])
}

@MainActor
@Test func historyOutboxTerminationWaitIsBoundedAndKeepsPendingData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = directory.appendingPathComponent("pending.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = WatchHistoryOutbox(
        store: store, activeAccount: { 7 },
        send: { _ in try await Task.sleep(for: .seconds(30)) })
    box.enqueue(.init(bvid: "BVexample", cid: 1, position: 42), accountID: 7)
    let start = Date()
    await box.drain(timeout: 0.1)
    #expect(Date().timeIntervalSince(start) < 1)
    let restored = WatchHistoryOutbox(
        store: store, automatic: false, activeAccount: { 7 }, send: { _ in })
    #expect(restored.entries.first?.progress.position == 42)
}

@Test func historyAPIRejectsAnotherAccountBeforeNetworkRequest() async {
    let api = BilibiliAPI(restoreSession: false)
    do {
        try await api.reportWatchProgress(
            bvid: "BVexample", cid: 1, position: 42, expectedUserID: 999)
        Issue.record("Missing account must not send")
    } catch {
        #expect((error as? APIError)?.code == -101)
    }
}
