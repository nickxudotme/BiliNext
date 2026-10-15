import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

private func interactionComment(_ id: Int64 = 7, likes: Int = 5, liked: Bool = false)
    -> BiliNextCore.Comment
{
    var comment = BiliNextCore.Comment(
        id: id, parentID: 0, rootID: 0, author: "测试", avatar: nil, text: "评论",
        likes: likes, replyCount: 0, date: .distantPast, replies: [])
    comment.liked = liked
    return comment
}

@MainActor
private final class CommentWriteGate {
    private var response: CheckedContinuation<Void, Error>?
    private var waiting: CheckedContinuation<Void, Never>?

    func suspend() async throws {
        try await withCheckedThrowingContinuation {
            response = $0
            waiting?.resume()
            waiting = nil
        }
    }

    func entered() async {
        if response != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func finish(_ error: Error? = nil) {
        if let error { response?.resume(throwing: error) } else { response?.resume() }
        response = nil
    }
}

@MainActor
struct CommentInteractionTests {
    private func context(user: Int64? = 42, aid: Int64 = 100, generation: UUID = UUID())
        -> CommentInteractionModel.Context
    {
        .init(aid: aid, bvid: "BV1111111111", userID: user, accountGeneration: generation)
    }

    @Test func anonymousLikeAsksForLoginWithoutSending() {
        let scope = context(user: nil)
        var writes = 0
        var logins = 0
        let model = CommentInteractionModel(
            context: { scope }, send: { _ in writes += 1 }, requireLogin: { logins += 1 },
            reportError: { _ in Issue.record("Anonymous action must not fail a request") })
        #expect(model.toggle(interactionComment()) == nil)
        #expect(writes == 0 && logins == 1 && model.busy.isEmpty)
    }

    @Test func confirmedLikesAreSharedAndBusyDeduplicatesEveryCopyOfAReply() async throws {
        let gate = CommentWriteGate()
        let scope = context()
        var writes: [CommentInteractionModel.Request] = []
        let model = CommentInteractionModel(
            context: { scope },
            send: { request in
                writes.append(request)
                if writes.count == 1 { try await gate.suspend() }
            }, requireLogin: {}, reportError: { _ in Issue.record("Expected success") })
        let listCopy = interactionComment()
        let first = try #require(model.toggle(listCopy))
        await gate.entered()
        #expect(model.isBusy(listCopy.id))
        #expect(model.toggle(interactionComment()) == nil && writes.count == 1)
        #expect(model.state(for: listCopy) == .init(liked: false, likes: 5))
        gate.finish()
        await first.value
        #expect(!model.isBusy(listCopy.id))
        // A preview, root, thread and dialog may all retain different server copies.
        for copy in [
            listCopy, interactionComment(likes: 4), interactionComment(likes: 6, liked: true),
        ] {
            #expect(model.state(for: copy) == .init(liked: true, likes: 6))
        }
        let second = try #require(model.toggle(listCopy))
        await second.value
        #expect(writes.map(\.liked) == [true, false])
        #expect(writes.allSatisfy { $0.context == scope && $0.replyID == listCopy.id })
        #expect(model.state(for: listCopy) == .init(liked: false, likes: 5))
    }

    @Test func differentRepliesCanWriteIndependentlyAndUnlikeNeverMakesANegativeCount()
        async throws
    {
        let gate = CommentWriteGate()
        let scope = context()
        let model = CommentInteractionModel(
            context: { scope }, send: { if $0.replyID == 7 { try await gate.suspend() } },
            requireLogin: {}, reportError: { _ in Issue.record("Expected success") })
        let first = try #require(model.toggle(interactionComment()))
        await gate.entered()
        let unlike = interactionComment(8, likes: 0, liked: true)
        let second = try #require(model.toggle(unlike))
        await second.value
        #expect(model.isBusy(7) && !model.isBusy(8))
        #expect(model.state(for: unlike) == .init(liked: false, likes: 0))
        gate.finish()
        await first.value
    }

    @Test func likingAPreviouslyDislikedReplyConfirmsALike() async throws {
        let scope = context()
        var sent: Bool?
        let model = CommentInteractionModel(
            context: { scope }, send: { sent = $0.liked }, requireLogin: {},
            reportError: { _ in Issue.record("Expected success") })
        let disliked = try #require(
            BiliNextCore.Comment.parse(["rpid": Int64(7), "like": 5, "action": 2]))
        await model.toggle(disliked)?.value
        #expect(sent == true && model.state(for: disliked) == .init(liked: true, likes: 6))
    }

    @Test func retainedPagesReadTheWorkspaceAccountAndItsReauthenticationGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let api = BilibiliAPI(restoreSession: false)
        let owner = AppModel(sessionStore: store, api: api)
        let page = AppModel(sessionStore: store, managesPlaybackTabs: false, api: api)
        page.tabOwner = owner
        owner.profile = UserProfile(id: 42, name: "当前账号")
        page.profile = UserProfile(id: 43, name: "尚未同步的旧账号")
        page.detail = VideoDetail(
            video: Video(bvid: "BV1111111111", title: "测试", aid: 100), pages: [], description: "")
        let first = try #require(CommentInteractionModel.context(for: page))
        #expect(first.userID == 42 && first.accountGeneration == owner.accountGeneration)
        owner.accountGeneration = UUID()
        let refreshed = try #require(CommentInteractionModel.context(for: page))
        #expect(refreshed != first && refreshed.userID == 42)
        owner.profile = nil
        #expect(CommentInteractionModel.context(for: page)?.userID == nil)
        page.stopMedia()
        owner.stopMedia()
    }

    @Test func failedLikesKeepTheirPreviousStateAndAllowRetry() async throws {
        let scope = context()
        var calls = 0
        var errors: [String] = []
        let model = CommentInteractionModel(
            context: { scope },
            send: { _ in
                calls += 1
                if calls == 1 { throw APIError(code: 12006, message: "评论已删除") }
            }, requireLogin: {}, reportError: { errors.append($0) })
        let comment = interactionComment()
        await model.toggle(comment)?.value
        #expect(errors == ["评论已删除（12006）"])
        #expect(!model.isBusy(comment.id))
        #expect(model.state(for: comment) == .init(liked: false, likes: 5))
        await model.toggle(comment)?.value
        #expect(calls == 2 && model.state(for: comment) == .init(liked: true, likes: 6))
    }

    @Test func expiredLoginPromptsAgainWithoutChangingTheCount() async {
        let scope = context()
        var logins = 0
        var errors: [String] = []
        let model = CommentInteractionModel(
            context: { scope }, send: { _ in throw APIError(code: -101, message: "请先登录") },
            requireLogin: { logins += 1 }, reportError: { errors.append($0) })
        let comment = interactionComment(liked: true)
        await model.toggle(comment)?.value
        #expect(logins == 1)
        #expect(errors == ["登录已失效，请重新扫码登录。"])
        #expect(model.state(for: comment) == .init(liked: true, likes: 5) && model.busy.isEmpty)
    }

    @Test(arguments: ["account", "video", "reauthenticate"])
    func changedContextRejectsAnOldSuccessWithoutAViewUpdate(_ change: String) async throws {
        let gate = CommentWriteGate()
        let original = context()
        var current = original
        var writes = 0
        let model = CommentInteractionModel(
            context: { current },
            send: { _ in
                writes += 1
                if writes == 1 { try await gate.suspend() }
            }, requireLogin: {}, reportError: { _ in Issue.record("Stale writes stay quiet") })
        let comment = interactionComment()
        let old = try #require(model.toggle(comment))
        await gate.entered()
        switch change {
        case "account": current = context(user: 43)
        case "video": current = context(aid: 200, generation: original.accountGeneration)
        default: current = context(generation: UUID())
        }
        // Simulates the account/video changing before SwiftUI delivers its onChange.
        gate.finish()
        await old.value
        #expect(!model.isBusy(comment.id) && model.busy.isEmpty)
        #expect(model.state(for: comment) == .init(liked: false, likes: 5))
        #expect(model.toggle(comment) == nil && writes == 1)
        // The host's account/video identity creates a fresh model and fresh API rows.
        let fresh = CommentInteractionModel(
            context: { current }, send: { _ in writes += 1 }, requireLogin: {},
            reportError: { _ in Issue.record("Expected success") })
        await fresh.toggle(comment)?.value
        #expect(writes == 2 && fresh.state(for: comment) == .init(liked: true, likes: 6))
    }

    @Test func changedAccountRejectsAnOldFailureWithoutAViewUpdate() async throws {
        let gate = CommentWriteGate()
        var current = context()
        var errors: [String] = []
        let model = CommentInteractionModel(
            context: { current }, send: { _ in try await gate.suspend() }, requireLogin: {},
            reportError: { errors.append($0) })
        let comment = interactionComment()
        let old = try #require(model.toggle(comment))
        await gate.entered()
        current = context(user: 43)
        gate.finish(APIError(code: -403, message: "旧账号的错误"))
        await old.value
        #expect(errors.isEmpty && model.busy.isEmpty)
        #expect(model.state(for: comment) == .init(liked: false, likes: 5))
        #expect(model.toggle(comment) == nil)
    }

    @Test func changingContextBeforeTheWriteStartsSendsNothing() async throws {
        var current = context()
        var writes = 0
        let model = CommentInteractionModel(
            context: { current }, send: { _ in writes += 1 }, requireLogin: {},
            reportError: { _ in Issue.record("Stale writes stay quiet") })
        let task = try #require(model.toggle(interactionComment()))
        current = context(user: 43)
        await task.value
        #expect(writes == 0)
    }

    @Test func backgroundWritesKeepConfirmationWithoutPresentingErrorsOrLogin() async throws {
        let gate = CommentWriteGate()
        let scope = context()
        var active = true
        var errors: [String] = []
        var logins = 0
        let model = CommentInteractionModel(
            context: { scope }, send: { _ in try await gate.suspend() },
            shouldPresentFeedback: { active }, requireLogin: { logins += 1 },
            reportError: { errors.append($0) })
        let comment = interactionComment()
        let like = try #require(model.toggle(comment))
        await gate.entered()
        active = false
        gate.finish()
        await like.value
        #expect(model.state(for: comment) == .init(liked: true, likes: 6))
        active = true
        let unlike = try #require(model.toggle(comment))
        await gate.entered()
        active = false
        gate.finish(APIError(code: -101, message: "请先登录"))
        await unlike.value
        #expect(errors.isEmpty && logins == 0 && model.busy.isEmpty)
        #expect(model.state(for: comment) == .init(liked: true, likes: 6))
    }

    @Test func cancellingThePanelRejectsLateErrorsAndDoesNotStrandBusyState() async throws {
        let gate = CommentWriteGate()
        let scope = context()
        var errors: [String] = []
        let model = CommentInteractionModel(
            context: { scope }, send: { _ in try await gate.suspend() }, requireLogin: {},
            reportError: { errors.append($0) })
        let comment = interactionComment()
        let task = try #require(model.toggle(comment))
        await gate.entered()
        model.cancel()
        gate.finish(APIError(code: -403, message: "迟到的错误"))
        await task.value
        #expect(task.isCancelled && errors.isEmpty && model.busy.isEmpty)
        #expect(model.state(for: comment) == .init(liked: false, likes: 5))
    }
}
