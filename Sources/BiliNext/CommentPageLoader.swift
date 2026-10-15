import BiliNextCore
import Combine
import Foundation

/// Request state belongs to one retained comment page, including while another page covers it.
@MainActor
final class CommentPageLoader: ObservableObject {
    enum Kind: Equatable {
        case list(newest: Bool)
        case thread(root: Int64)
        case dialog(root: Int64, id: Int64)
    }

    struct Scope: Equatable {
        let aid: Int64
        let kind: Kind
    }

    struct Request: Equatable {
        let scope: Scope
        let page: Int
    }

    struct Result {
        var comments: [Comment]
        var count: Int
        var hasMore: Bool
        var uploaderID: Int64 = 0
    }

    typealias Fetch = (Request) async throws -> Result

    @Published private(set) var comments: [Comment] = []
    @Published private(set) var count = 0
    @Published private(set) var page = 0
    @Published private(set) var more = true
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var uploaderID: Int64 = 0
    @Published private(set) var pendingFocus: Int64?
    private(set) var scope: Scope?
    private(set) var task: Task<Void, Never>?
    private var active = false
    private var resumeLoad = false
    private var focus: Comment?
    private var generation = UUID()
    private let fetch: Fetch

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    convenience init(api: BilibiliAPI) {
        self.init { request in
            switch request.scope.kind {
            case .list(let newest):
                let result = try await api.comments(
                    aid: request.scope.aid, page: request.page, newest: newest)
                return Result(
                    comments: result.comments, count: result.count, hasMore: result.hasMore,
                    uploaderID: result.uploaderID)
            case .thread(let root):
                let result = try await api.comments(
                    aid: request.scope.aid, page: request.page, root: root)
                return Result(
                    comments: result.comments, count: result.count, hasMore: result.hasMore)
            case .dialog(let root, let id):
                let comments = try await api.dialog(aid: request.scope.aid, root: root, dialog: id)
                return Result(comments: comments, count: comments.count, hasMore: false)
            }
        }
    }

    deinit { task?.cancel() }

    /// Called for both visibility and video/sort changes. Covered pages keep their data.
    func update(scope newScope: Scope?, active: Bool, focus: Comment? = nil) {
        if scope != newScope {
            cancel()
            scope = newScope
            comments = []
            count = 0
            page = 0
            more = newScope != nil
            error = nil
            uploaderID = 0
            self.focus = focus
            pendingFocus = focus?.id
            resumeLoad = false
        }
        self.active = active && newScope != nil
        if !self.active {
            if task != nil { resumeLoad = true }
            cancel()
            return
        }
        if page == 0 || resumeLoad || needsFocusPage {
            resumeLoad = false
            loadNext()
        }
    }

    func deactivate() {
        update(scope: scope, active: false)
    }

    func retry() {
        error = nil
        loadNext()
    }

    func revealFocus(_ id: Int64) {
        if pendingFocus == id { pendingFocus = nil }
    }

    func loadNext() {
        guard active, let scope, !loading, more, error == nil else { return }
        let request = Request(scope: scope, page: page + 1)
        let token = UUID()
        generation = token
        loading = true
        task = Task { [weak self, fetch] in
            do {
                let result = try await fetch(request)
                guard !Task.isCancelled else { return }
                self?.receive(result, request: request, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error, request: request, token: token)
            }
        }
    }

    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        loading = false
    }

    private var needsFocusPage: Bool {
        guard let pendingFocus else { return false }
        return !comments.contains(where: { $0.id == pendingFocus }) && more && page < 10
    }

    private func receive(_ result: Result, request: Request, token: UUID) {
        guard active, scope == request.scope, generation == token else { return }
        var seen = Set(comments.map(\.id))
        comments += result.comments.filter { seen.insert($0.id).inserted }
        count = result.count
        more = result.hasMore
        page = request.page
        if result.uploaderID != 0 { uploaderID = result.uploaderID }
        loading = false
        task = nil
        if needsFocusPage {
            loadNext()
        } else {
            insertFocusIfMissing()
        }
    }

    private func failed(_ error: Error, request: Request, token: UUID) {
        guard active, scope == request.scope, generation == token else { return }
        loading = false
        task = nil
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            resumeLoad = true
            return
        }
        self.error = error.localizedDescription
        insertFocusIfMissing()
    }

    private func insertFocusIfMissing() {
        if let pendingFocus, let focus, !comments.contains(where: { $0.id == pendingFocus }) {
            comments.insert(focus, at: 0)
        }
    }
}
