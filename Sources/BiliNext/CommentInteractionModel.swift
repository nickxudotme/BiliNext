import BiliNextCore
import Foundation
import Observation

/// Shared by the list, previews, thread and dialog inside one video's comment panel.
@MainActor @Observable
final class CommentInteractionModel {
    /// Which video and sign-in the panel's comments belong to. Equality leaves out `userID`:
    /// at launch the profile arrives after comments already fetched with that account's
    /// cookies, and a real account change always starts a new `accountGeneration`.
    struct Context: Hashable {
        let aid: Int64
        let bvid: String
        let userID: Int64?
        let accountGeneration: UUID

        static func == (lhs: Context, rhs: Context) -> Bool {
            lhs.aid == rhs.aid && lhs.bvid == rhs.bvid
                && lhs.accountGeneration == rhs.accountGeneration
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(aid)
            hasher.combine(bvid)
            hasher.combine(accountGeneration)
        }
    }

    struct State: Equatable {
        let liked: Bool
        let likes: Int
    }

    struct Request: Equatable {
        let context: Context
        let replyID: Int64
        let liked: Bool
    }

    private let context: Context?
    private var confirmed: [Int64: State] = [:]
    private(set) var busy = Set<Int64>()
    @ObservationIgnored private var tasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    private let currentContext: () -> Context?
    private let send: (Request) async throws -> Void
    private let shouldPresentFeedback: () -> Bool
    private let requireLogin: () -> Void
    private let reportError: (String) -> Void

    init(
        context: @escaping () -> Context?, send: @escaping (Request) async throws -> Void,
        shouldPresentFeedback: @escaping () -> Bool = { true },
        requireLogin: @escaping () -> Void, reportError: @escaping (String) -> Void
    ) {
        currentContext = context
        self.send = send
        self.shouldPresentFeedback = shouldPresentFeedback
        self.requireLogin = requireLogin
        self.reportError = reportError
        self.context = context()
    }

    convenience init(model: AppModel) {
        self.init(
            context: { [weak model] in model.flatMap(Self.context(for:)) },
            send: { [api = model.api] request in
                guard let userID = request.context.userID else { throw CancellationError() }
                try await api.likeComment(
                    aid: request.context.aid, replyID: request.replyID, liked: request.liked,
                    expectedUserID: userID)
            },
            shouldPresentFeedback: { [weak model] in model?.playbackTabActive == true },
            requireLogin: { [weak model] in model?.loginPresented = true },
            reportError: { [weak model] in model?.toast = $0 })
    }

    static func context(for model: AppModel) -> Context? {
        let owner = model.tabOwner ?? model
        guard let video = model.detail?.video, let aid = video.aid, aid > 0 else { return nil }
        return Context(
            aid: aid, bvid: video.bvid, userID: owner.profile?.id,
            accountGeneration: owner.accountGeneration)
    }

    deinit { for task in tasks.values { task.cancel() } }

    func state(for comment: Comment) -> State {
        guard context == currentContext(), let value = confirmed[comment.id] else {
            return State(liked: comment.liked, likes: max(0, comment.likes))
        }
        return value
    }

    func isBusy(_ replyID: Int64) -> Bool {
        context == currentContext() && busy.contains(replyID)
    }

    func cancel() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]
        busy = []
    }

    @discardableResult
    func toggle(_ comment: Comment) -> Task<Void, Never>? {
        // The host rebuilds for a new video/account. An old rendered row must never
        // turn its old action flag into a write for the new context.
        guard context == currentContext() else {
            cancel()
            return nil
        }
        // The account may have finished loading after this panel was built.
        guard let context = currentContext(), context.aid > 0, comment.id > 0 else { return nil }
        guard let userID = context.userID, userID > 0 else {
            requireLogin()
            return nil
        }
        guard !busy.contains(comment.id) else { return nil }
        let before = state(for: comment)
        let request = Request(context: context, replyID: comment.id, liked: !before.liked)
        let token = generation
        busy.insert(comment.id)
        let provider = currentContext
        let task = Task { [weak self, send] in
            defer { self?.finish(request, token: token) }
            guard !Task.isCancelled, provider() == request.context else { return }
            do {
                try await send(request)
                guard !Task.isCancelled else { return }
                self?.succeeded(request, before: before, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error, request: request, token: token)
            }
        }
        tasks[comment.id] = task
        return task
    }

    private func isCurrent(_ request: Request, token: UUID) -> Bool {
        generation == token && context == request.context && currentContext() == request.context
    }

    private func finish(_ request: Request, token: UUID) {
        guard generation == token, context == request.context else { return }
        busy.remove(request.replyID)
        tasks[request.replyID] = nil
    }

    private func succeeded(_ request: Request, before: State, token: UUID) {
        guard isCurrent(request, token: token) else { return }
        let likes = request.liked ? before.likes + 1 : max(0, before.likes - 1)
        confirmed[request.replyID] = State(liked: request.liked, likes: likes)
    }

    private func failed(_ error: Error, request: Request, token: UUID) {
        guard isCurrent(request, token: token) else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        // Retained background tabs keep successful writes, but cannot interrupt the
        // currently visible video with their error toast or an expired-login prompt.
        guard shouldPresentFeedback() else { return }
        if (error as? APIError)?.code == -101 { requireLogin() }
        reportError(error.localizedDescription)
    }
}
