import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

struct BrowsePageRequest: Sendable {
    let destination: BrowseDestination
    let homeSection: String
    let keyword: String
    let libraryKeyword: String
    let favoriteOrder: String
    let searchOrder: String
    let memberID: Int64?
    var folderID: Int64
    var page: Int
    var offset: String?
    var reloadFolders: Bool

    var usesCursor: Bool {
        destination == .dynamic || (destination == .history && libraryKeyword.isEmpty)
    }

    var usesFeedContinuation: Bool {
        [.dynamic, .favorites, .history, .watchLater].contains(destination)
    }

    var cacheKey: String {
        switch destination {
        case .favorites: "收藏:\(folderID):\(libraryKeyword):\(favoriteOrder)"
        case .search: "搜索:\(keyword):\(searchOrder)"
        case .home: "首页:\(homeSection)"
        case .history: "历史:\(libraryKeyword)"
        case .dynamic, .watchLater: destination.rawValue
        }
    }
}

struct BrowsePageResult: Sendable {
    let videos: [Video]
    let next: String?
    var folders: [FavoriteFolder]? = nil
    var folderID: Int64? = nil
}

extension AppModel {
    // MARK: - Browsing and library

    var canBack: Bool { selected != nil || historyIndex > 0 }
    var canForward: Bool {
        if let selected, tabs.first(where: { $0.id == selected })?.trail.forward.isEmpty == false {
            return true
        }
        return historyIndex < history.count - 1
    }
    func navigate(_ destination: BrowseDestination) {
        if let tabOwner {
            tabOwner.navigate(destination)
            return
        }
        hoverPreview.stop()
        suspendPlaybackTabs()
        if miniPlayer { toggleMiniPlayer() }
        selected = nil
        menu = destination
        libraryQuery = ""
        let route = browsePageID(for: destination)
        if !history.indices.contains(historyIndex) || history[historyIndex] != route {
            history = Array(history.prefix(historyIndex + 1))
            history.append(route)
            historyIndex = history.count - 1
        }
        if destination == .history { refresh() } else { loadBrowseIfNeeded() }
    }
    func moveHistory(_ delta: Int) {
        if let tabOwner {
            tabOwner.moveHistory(delta)
            return
        }
        // Inside a tab, first step through the videos it played in place.
        if stepTabTrail(delta) { return }
        suspendPlaybackTabs()
        if selected != nil && delta < 0 {
            selected = nil
            if menu == .history { refresh() } else { loadBrowseIfNeeded() }
            return
        }
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        historyIndex = next
        restoreBrowseRoute(history[next])
        selected = nil
        if menu == .history { refresh() } else { loadBrowseIfNeeded() }
    }

    private func restoreBrowseRoute(_ route: String) {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        guard let destination = parts.first.flatMap(BrowseDestination.init(rawValue:)) else {
            return
        }
        menu = destination
        guard parts.count == 2 else { return }
        switch menu {
        case .home: homeSection = parts[1]
        case .dynamic: dynamicMode = parts[1]
        case .favorites: folderID = Int64(parts[1]) ?? 0
        case .search, .history, .watchLater: break
        }
    }

    func selectBrowseSection(destination: BrowseDestination, section: String) {
        if let tabOwner {
            tabOwner.selectBrowseSection(destination: destination, section: section)
            return
        }
        switch destination {
        case .home: homeSection = section
        case .dynamic: dynamicMode = section
        case .search, .favorites, .history, .watchLater: return
        }
        navigate(destination)
    }

    /// Opens the search page with a keyword typed elsewhere, such as the browse toolbar.
    func search(_ keyword: String) {
        if let tabOwner {
            tabOwner.search(keyword)
            return
        }
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        if let bvid = Video.extractBVID(keyword) {
            open(Video(bvid: bvid, title: bvid))
            return
        }
        open(Video(bvid: SearchResultsTab.id(keyword), title: "搜索：" + keyword))
    }

    func selectFavoriteFolder(_ id: Int64) {
        if let tabOwner {
            tabOwner.selectFavoriteFolder(id)
            return
        }
        folderID = id
        navigate(.favorites)
    }

    func loadBrowseIfNeeded() {
        guard selected == nil else { return }
        if managesPlaybackTabs {
            browseInstance(for: menu).loadBrowseIfNeeded()
            return
        }
        guard !loading, !browseLoadAttempted, browseContext == nil, videos.isEmpty,
            browseError == nil
        else { return }
        // An anonymous page is still unattempted: startup/login may make it available later.
        guard !menu.requiresLogin || profile != nil else { return }
        refresh()
    }

    func invalidateBrowseCache() {
        browseTask?.cancel()
        browseTask = nil
        browseGeneration = UUID()
        browseLoadAttempted = false
        cachedLists = [:]
        browseContext = nil
        browseRequestedOffsets = []
        browseRetryMore = false
        videos = []
        folders = []
        browseError = nil
        loading = false
        hasMore = false
        page = 0
        offset = nil
    }
    func refresh(more: Bool = false) {
        if managesPlaybackTabs, selected == nil {
            browseInstance(for: menu).refresh(more: more)
            return
        }
        guard selected == nil else {
            if let id = selected { activate(id, force: true) }
            return
        }
        if more && (loading || !hasMore) { return }
        browseTask?.cancel()
        let generation = UUID()
        browseGeneration = generation
        let destination = menu
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryKeyword = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = BrowsePageRequest(
            destination: destination, homeSection: homeSection, keyword: keyword,
            libraryKeyword: libraryKeyword, favoriteOrder: favoriteOrder, searchOrder: searchOrder,
            memberID: profile?.id, folderID: folderID, page: 1, offset: more ? offset : nil,
            reloadFolders: !more)
        if more {
            if let context = browseContext {
                request = context
                request.reloadFolders = false
            }
            request.page = request.usesCursor ? page + 1 : (offset.flatMap(Int.init) ?? page + 1)
            request.offset = offset
        }
        let watchLaterContext =
            request.destination == .watchLater ? watchLaterReadContext() : nil
        let watchLaterState = (tabOwner ?? self).watchLaterSynchronization
        if more, request.destination == .watchLater,
            watchLaterState.needsPaginationRestart(self)
        {
            // Page-number boundaries move after membership changes. Re-read from the start,
            // merging into the retained list, so deleting earlier items cannot skip a page.
            request.page = 1
            request.offset = nil
        }
        if !more {
            if menu == .dynamic, profile != nil { followedLives.refresh() }
            page = 0
            offset = nil
            browseRequestedOffsets = []
            browseContext = nil
            videos = cachedLists[request.cacheKey] ?? []
            hasMore = false
        }
        browseError = nil
        browseRetryMore = more
        if request.destination.requiresLogin && profile == nil {
            videos = []
            browseLoadAttempted = false
            loading = false
            hasMore = false
            return
        }
        if request.destination == .dynamic && dynamicMode == "全部" {
            browseLoadAttempted = true
            loading = false
            timelineRefresh += 1
            return
        }
        if request.destination == .home && request.homeSection == "番剧" {
            browseLoadAttempted = true
            loading = false
            catalogRefresh += 1
            return
        }
        if request.destination == .search && request.keyword.isEmpty {
            browseLoadAttempted = true
            videos = []
            loading = false
            hasMore = false
            return
        }
        if request.destination == .search, let bvid = Video.extractBVID(request.keyword) {
            browseLoadAttempted = true
            loading = false
            open(Video(bvid: bvid, title: bvid))
            return
        }
        browseLoadAttempted = true
        loading = true
        browseTask = Task {
            defer {
                if generation == browseGeneration { loading = false }
            }
            do {
                // Publish each successful page immediately; prefetching must not delay the first.
                for index in 0..<(more ? 2 : 3) {
                    guard !Task.isCancelled, generation == browseGeneration else { return }
                    if request.usesCursor, let cursor = request.offset {
                        browseRequestedOffsets.insert(cursor)
                    }
                    let result = try await browsePageLoader(request)
                    guard !Task.isCancelled, generation == browseGeneration else { return }
                    if let watchLaterContext,
                        !matchesWatchLaterAccount(watchLaterContext)
                    {
                        return
                    }
                    if let available = result.folders { folders = available }
                    if let actualFolder = result.folderID {
                        folderID = actualFolder
                        request.folderID = actualFolder
                    }
                    let replacing = !more && index == 0
                    let previousCount = replacing ? 0 : videos.count
                    var seen = Set<String>()
                    var updated = ((replacing ? [] : videos) + result.videos).filter {
                        seen.insert($0.id).inserted
                    }
                    if let watchLaterContext {
                        updated = watchLaterState.reconcile(updated, since: watchLaterContext)
                        watchLaterState.acceptedRead(self, context: watchLaterContext)
                    }
                    videos = updated
                    if replacing { browseRevision += 1 }
                    cachedLists[request.cacheKey] = videos
                    browseContext = request
                    page = request.page
                    let next = result.next.flatMap { $0.isEmpty ? nil : $0 }
                    offset = next
                    let advances =
                        request.usesCursor
                        ? next.map { !browseRequestedOffsets.contains($0) } ?? false
                        : next.flatMap(Int.init).map { $0 > request.page } ?? false
                    // Feed.next reflects the API's has_more, including pages whose non-video
                    // resources were filtered out. Array-only endpoints have no such metadata.
                    hasMore =
                        advances
                        && (request.usesFeedContinuation
                            || (!result.videos.isEmpty && videos.count > previousCount))
                    if let watchLaterContext,
                        watchLaterReadContext()?.revision != watchLaterContext.revision,
                        watchLaterState.needsPaginationRestart(self)
                    {
                        // The old last-page response cannot close the load-more entry point:
                        // its boundary predates a confirmed membership change.
                        hasMore = true
                    }
                    browseRetryMore = true
                    if let watchLaterContext,
                        watchLaterReadContext()?.revision != watchLaterContext.revision
                    {
                        break
                    }
                    guard hasMore, let next else { break }
                    request.page =
                        request.usesCursor ? request.page + 1 : (Int(next) ?? request.page + 1)
                    request.offset = next
                    request.reloadFolders = false
                }
            } catch {
                guard !Task.isCancelled, generation == browseGeneration else { return }
                if let watchLaterContext, !matchesWatchLaterAccount(watchLaterContext) { return }
                browseError = error.localizedDescription
            }
        }
    }
    func retryBrowse() {
        refresh(more: browseRetryMore)
    }

    static func loadBrowsePage(_ request: BrowsePageRequest, api: BilibiliAPI) async throws
        -> BrowsePageResult
    {
        switch request.destination {
        case .dynamic:
            let feed = try await api.feed(offset: request.offset)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case .favorites:
            guard let mid = request.memberID else { throw APIError(code: -101, message: "请先登录") }
            let available = request.reloadFolders ? try await api.favoriteFolders(mid: mid) : nil
            try Task.checkCancellation()
            let actualFolder: Int64
            if let available {
                actualFolder =
                    (available.first(where: { $0.id == request.folderID }) ?? available.first)?.id
                    ?? 0
            } else {
                actualFolder = request.folderID
            }
            guard actualFolder != 0 else {
                return BrowsePageResult(videos: [], next: nil, folders: available, folderID: 0)
            }
            let feed = try await api.favorites(
                folder: actualFolder, page: request.page, keyword: request.libraryKeyword,
                order: request.favoriteOrder)
            return BrowsePageResult(
                videos: feed.videos, next: feed.next, folders: available, folderID: actualFolder)
        case .watchLater:
            let feed = try await api.watchLater(page: request.page)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case .history:
            let feed =
                try await request.libraryKeyword.isEmpty
                ? api.watchHistory(cursor: request.offset)
                : api.searchHistory(keyword: request.libraryKeyword, page: request.page)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case .search:
            let videos = try await api.search(
                request.keyword, page: request.page, order: request.searchOrder)
            return BrowsePageResult(
                videos: videos, next: videos.isEmpty ? nil : String(request.page + 1))
        case .home:
            if request.homeSection == "排行榜" {
                return BrowsePageResult(videos: try await api.ranking(), next: nil)
            }
            let videos =
                try await request.homeSection == "热门"
                ? api.popular(page: request.page) : api.recommended(page: request.page)
            return BrowsePageResult(
                videos: videos, next: videos.isEmpty ? nil : String(request.page + 1))
        }
    }
    func loadMoreIfNeeded() {
        guard selected == nil, hasMore, !loading, browseError == nil, !videos.isEmpty else {
            return
        }
        refresh(more: true)
    }
    func selectFolder(_ id: Int64) {
        if let tabOwner {
            tabOwner.selectFavoriteFolder(id)
            return
        }
        guard id != folderID else { return }
        folderID = id
        refresh()
    }
    @discardableResult
    func changeWatchLater(_ video: Video, remove: Bool = false) -> Task<Void, Never>? {
        let owner = tabOwner ?? self
        guard let context = watchLaterReadContext() else {
            loginPresented = true
            return nil
        }
        let state = owner.watchLaterSynchronization
        guard let token = state.begin(video.id) else { return nil }
        owner.publishWatchLaterBusy()
        return Task {
            defer {
                state.finish(video.id, token: token)
                owner.publishWatchLaterBusy()
            }
            guard matchesWatchLaterAccount(context) else { return }
            do {
                if remove {
                    guard let aid = video.aid else {
                        throw APIError(code: -1, message: "无法识别视频编号，请刷新列表")
                    }
                    try await api.removeFromWatchLater(
                        aid: aid, expectedUserID: context.accountID)
                } else {
                    try await api.addToWatchLater(
                        bvid: video.bvid, expectedUserID: context.accountID)
                }
                guard matchesWatchLaterAccount(context) else { return }
                owner.watchLaterDidChange(video, remove: remove)
                toast = remove ? "已从稍后再看移除" : "已加入稍后再看"
            } catch {
                guard matchesWatchLaterAccount(context) else { return }
                toast = error.localizedDescription
            }
        }
    }

}
