import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

/// Deliberately ignores cancellation, like a response already queued for delivery.
@MainActor
private final class CommentFetchGate {
    private var continuation: CheckedContinuation<CommentPageLoader.Result, Error>?
    private var entered: CheckedContinuation<Void, Never>?

    func suspend() async throws -> CommentPageLoader.Result {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitForEntry() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release(_ result: CommentPageLoader.Result) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private func lifecycleComment(_ id: Int64) -> BiliNextCore.Comment {
    BiliNextCore.Comment(
        id: id, parentID: 10, rootID: 10, author: "离线测试", avatar: nil, text: "回复 \(id)",
        likes: 0, replyCount: 0, date: .distantPast, replies: [])
}

private func lifecycleResult(_ ids: [Int64], more: Bool = true) -> CommentPageLoader.Result {
    .init(comments: ids.map(lifecycleComment), count: 300, hasMore: more, uploaderID: 8)
}

@MainActor
private func finishCommentLoads(_ loader: CommentPageLoader) async {
    for _ in 0..<20 {
        guard let task = loader.task else { return }
        await task.value
    }
    Issue.record("评论加载未在预期页数内结束")
}

@MainActor
@Suite struct CommentPageLifecycleTests {
    @Test func coveredThreadCancelsFocusPagingAndResumesTheSamePage() async throws {
        let gate = CommentFetchGate()
        var requests: [CommentPageLoader.Request] = []
        let loader = CommentPageLoader { request in
            requests.append(request)
            if requests.count == 2 { return try await gate.suspend() }
            return lifecycleResult(request.page == 1 ? [1] : [1, 2, 99])
        }
        let scope = CommentPageLoader.Scope(aid: 100, kind: .thread(root: 10))
        loader.update(scope: scope, active: true, focus: lifecycleComment(99))
        await gate.waitForEntry()
        let coveredTask = try #require(loader.task)
        loader.deactivate()
        #expect(coveredTask.isCancelled && !loader.loading && loader.error == nil)
        gate.release(lifecycleResult([2]))
        await coveredTask.value
        #expect(requests.map(\.page) == [1, 2])
        #expect(loader.page == 1 && loader.comments.map(\.id) == [1])
        #expect(loader.pendingFocus == 99)

        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        #expect(requests.map(\.page) == [1, 2, 2])
        #expect(requests.allSatisfy { $0.scope == scope })
        #expect(loader.comments.map(\.id) == [1, 2, 99] && loader.page == 2)
        loader.revealFocus(99)
        loader.deactivate()
        loader.update(scope: scope, active: true)
        #expect(requests.count == 3 && loader.pendingFocus == nil)
    }

    @Test func replacingVideoRejectsOldCommentsAndKeepsItsNewRequestLoading() async throws {
        let oldGate = CommentFetchGate()
        let newGate = CommentFetchGate()
        let oldScope = CommentPageLoader.Scope(aid: 100, kind: .list(newest: false))
        let newScope = CommentPageLoader.Scope(aid: 200, kind: .list(newest: false))
        var requests: [CommentPageLoader.Request] = []
        let loader = CommentPageLoader { request in
            requests.append(request)
            return try await (request.scope == oldScope ? oldGate : newGate).suspend()
        }
        loader.update(scope: oldScope, active: true)
        await oldGate.waitForEntry()
        let oldTask = try #require(loader.task)
        loader.update(scope: newScope, active: true)
        await newGate.waitForEntry()
        oldGate.release(lifecycleResult([1]))
        await oldTask.value
        #expect(oldTask.isCancelled && loader.loading && loader.comments.isEmpty)
        #expect(loader.error == nil && loader.page == 0 && requests.map(\.scope.aid) == [100, 200])
        newGate.release(lifecycleResult([2], more: false))
        await finishCommentLoads(loader)
        #expect(loader.comments.map(\.id) == [2] && !loader.more && loader.page == 1)
    }

    @Test func changingSortRejectsThePreviousSortsLateError() async throws {
        let gate = CommentFetchGate()
        let hot = CommentPageLoader.Scope(aid: 100, kind: .list(newest: false))
        let newest = CommentPageLoader.Scope(aid: 100, kind: .list(newest: true))
        let loader = CommentPageLoader { request in
            if request.scope == hot { return try await gate.suspend() }
            return lifecycleResult([2], more: false)
        }
        loader.update(scope: hot, active: true)
        await gate.waitForEntry()
        let oldTask = try #require(loader.task)
        loader.update(scope: newest, active: true)
        await finishCommentLoads(loader)
        gate.fail(URLError(.timedOut))
        await oldTask.value
        #expect(oldTask.isCancelled && loader.error == nil && loader.comments.map(\.id) == [2])
    }

    @Test(arguments: [
        CommentPageLoader.Kind.list(newest: false), .thread(root: 10), .dialog(root: 10, id: 11),
    ])
    func leavingAnyCommentPageCancelsItsRequestWithoutAnError(_ kind: CommentPageLoader.Kind)
        async throws
    {
        let gate = CommentFetchGate()
        let loader = CommentPageLoader { _ in try await gate.suspend() }
        loader.update(scope: .init(aid: 100, kind: kind), active: true)
        await gate.waitForEntry()
        let task = try #require(loader.task)
        loader.deactivate()
        gate.fail(URLError(.cancelled))
        await task.value
        #expect(task.isCancelled && !loader.loading && loader.error == nil)
        #expect(loader.comments.isEmpty && loader.page == 0)
    }

    @Test func returningToALoadedDialogKeepsItsDataWithoutFetchingAgain() async {
        var calls = 0
        let loader = CommentPageLoader { _ in
            calls += 1
            return lifecycleResult([11], more: false)
        }
        let scope = CommentPageLoader.Scope(aid: 100, kind: .dialog(root: 10, id: 11))
        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        loader.deactivate()
        loader.loadNext()
        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        #expect(calls == 1 && loader.comments.map(\.id) == [11])
    }

    @Test func cancelledAppendKeepsLoadedCommentsAndDoesNotSkipOrDuplicatePages() async throws {
        let gate = CommentFetchGate()
        var pages: [Int] = []
        let loader = CommentPageLoader { request in
            pages.append(request.page)
            if pages.count == 2 { return try await gate.suspend() }
            return lifecycleResult(request.page == 1 ? [1] : [1, 2])
        }
        let scope = CommentPageLoader.Scope(aid: 100, kind: .list(newest: false))
        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        loader.loadNext()
        await gate.waitForEntry()
        let old = try #require(loader.task)
        loader.deactivate()
        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        gate.release(lifecycleResult([3]))
        await old.value
        #expect(pages == [1, 2, 2] && loader.comments.map(\.id) == [1, 2])
        #expect(loader.page == 2 && loader.error == nil)
    }

    @Test func locatingFocusStopsAfterTenPagesAndKeepsThePreviewFallbackOnce() async {
        var requests: [CommentPageLoader.Request] = []
        let loader = CommentPageLoader { request in
            requests.append(request)
            return lifecycleResult([Int64(request.page)])
        }
        let scope = CommentPageLoader.Scope(aid: 100, kind: .thread(root: 10))
        loader.update(scope: scope, active: true, focus: lifecycleComment(99))
        await finishCommentLoads(loader)
        #expect(requests.map(\.page) == Array(1...10))
        #expect(loader.comments.first?.id == 99 && loader.comments.count == 11)
        loader.revealFocus(99)
        loader.deactivate()
        loader.update(scope: scope, active: true)
        await finishCommentLoads(loader)
        #expect(requests.count == 10 && loader.comments.filter { $0.id == 99 }.count == 1)
    }

    @Test func focusFallbackAlsoSurvivesEndOfRepliesAndNetworkErrors() async {
        for shouldFail in [false, true] {
            let loader = CommentPageLoader { _ in
                if shouldFail { throw URLError(.timedOut) }
                return lifecycleResult([], more: false)
            }
            loader.update(
                scope: .init(aid: 100, kind: .thread(root: 10)), active: true,
                focus: lifecycleComment(99))
            await finishCommentLoads(loader)
            #expect(loader.comments.map(\.id) == [99])
            #expect((loader.error != nil) == shouldFail)
        }
    }

    @Test func absentVideoCannotStartRequestsAndAPageErrorRetriesTheSamePage() async {
        var pages: [Int] = []
        let loader = CommentPageLoader { request in
            pages.append(request.page)
            if pages.count == 1 { throw URLError(.timedOut) }
            return lifecycleResult([1], more: false)
        }
        loader.update(scope: nil, active: true)
        loader.loadNext()
        #expect(pages.isEmpty && !loader.loading)
        loader.update(scope: .init(aid: 100, kind: .list(newest: false)), active: true)
        await finishCommentLoads(loader)
        #expect(loader.error != nil && loader.page == 0)
        loader.retry()
        await finishCommentLoads(loader)
        #expect(pages == [1, 1] && loader.error == nil && loader.page == 1)
    }
}
