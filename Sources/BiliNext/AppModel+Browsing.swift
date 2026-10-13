import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

struct BrowsePageRequest: Sendable {
    let destination: String
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
        destination == "动态" || (destination == "历史" && libraryKeyword.isEmpty)
    }

    var usesFeedContinuation: Bool {
        ["动态", "收藏", "历史", "稍后再看"].contains(destination)
    }

    var cacheKey: String {
        switch destination {
        case "收藏": "收藏:\(folderID):\(libraryKeyword):\(favoriteOrder)"
        case "搜索": "搜索:\(keyword):\(searchOrder)"
        case "首页": "首页:\(homeSection)"
        case "历史": "历史:\(libraryKeyword)"
        default: destination
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
    var canForward: Bool { historyIndex < history.count - 1 }
    func navigate(_ destination: String) {
        if let tabOwner {
            tabOwner.navigate(destination)
            return
        }
        hoverPreview.stop()
        suspendPlaybackTabs()
        selected = nil
        menu = destination
        libraryQuery = ""
        let route = browsePageID(for: destination)
        if !history.indices.contains(historyIndex) || history[historyIndex] != route {
            history = Array(history.prefix(historyIndex + 1))
            history.append(route)
            historyIndex = history.count - 1
        }
        if destination == "历史" { refresh() } else { loadBrowseIfNeeded() }
    }
    func moveHistory(_ delta: Int) {
        if let tabOwner {
            tabOwner.moveHistory(delta)
            return
        }
        suspendPlaybackTabs()
        if selected != nil && delta < 0 {
            selected = nil
            if menu == "历史" { refresh() } else { loadBrowseIfNeeded() }
            return
        }
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        historyIndex = next
        restoreBrowseRoute(history[next])
        selected = nil
        if menu == "历史" { refresh() } else { loadBrowseIfNeeded() }
    }

    private func restoreBrowseRoute(_ route: String) {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        guard let destination = parts.first else { return }
        menu = destination
        guard parts.count == 2 else { return }
        switch menu {
        case "首页": homeSection = parts[1]
        case "动态": dynamicMode = parts[1]
        case "收藏": folderID = Int64(parts[1]) ?? 0
        default: break
        }
    }

    func selectBrowseSection(destination: String, section: String) {
        if let tabOwner {
            tabOwner.selectBrowseSection(destination: destination, section: section)
            return
        }
        switch destination {
        case "首页": homeSection = section
        case "动态": dynamicMode = section
        default: return
        }
        navigate(destination)
    }

    func selectFavoriteFolder(_ id: Int64) {
        if let tabOwner {
            tabOwner.selectFavoriteFolder(id)
            return
        }
        folderID = id
        navigate("收藏")
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
        guard !["动态", "收藏", "历史", "稍后再看"].contains(menu) || profile != nil else { return }
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
        if !more {
            page = 0
            offset = nil
            browseRequestedOffsets = []
            browseContext = nil
            videos = cachedLists[request.cacheKey] ?? []
            hasMore = false
        }
        browseError = nil
        browseRetryMore = more
        if ["动态", "收藏", "历史", "稍后再看"].contains(request.destination) && profile == nil {
            videos = []
            browseLoadAttempted = false
            loading = false
            hasMore = false
            return
        }
        if request.destination == "动态" && dynamicMode == "全部" {
            browseLoadAttempted = true
            loading = false
            timelineRefresh += 1
            return
        }
        if request.destination == "首页" && request.homeSection == "番剧" {
            browseLoadAttempted = true
            loading = false
            catalogRefresh += 1
            return
        }
        if request.destination == "搜索" && request.keyword.isEmpty {
            browseLoadAttempted = true
            videos = []
            loading = false
            hasMore = false
            return
        }
        if request.destination == "搜索", let bvid = Video.extractBVID(request.keyword) {
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
                    if let available = result.folders { folders = available }
                    if let actualFolder = result.folderID {
                        folderID = actualFolder
                        request.folderID = actualFolder
                    }
                    let replacing = !more && index == 0
                    let previousCount = replacing ? 0 : videos.count
                    var seen = Set<String>()
                    videos = ((replacing ? [] : videos) + result.videos).filter {
                        seen.insert($0.id).inserted
                    }
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
                    browseRetryMore = true
                    guard hasMore, let next else { break }
                    request.page =
                        request.usesCursor ? request.page + 1 : (Int(next) ?? request.page + 1)
                    request.offset = next
                    request.reloadFolders = false
                }
            } catch {
                guard !Task.isCancelled, generation == browseGeneration else { return }
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
        case "动态":
            let feed = try await api.feed(offset: request.offset)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case "收藏":
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
        case "稍后再看":
            let feed = try await api.watchLater(page: request.page)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case "历史":
            let feed =
                try await request.libraryKeyword.isEmpty
                ? api.watchHistory(cursor: request.offset)
                : api.searchHistory(keyword: request.libraryKeyword, page: request.page)
            return BrowsePageResult(videos: feed.videos, next: feed.next)
        case "搜索":
            let videos = try await api.search(
                request.keyword, page: request.page, order: request.searchOrder)
            return BrowsePageResult(
                videos: videos, next: videos.isEmpty ? nil : String(request.page + 1))
        default:
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
    func changeWatchLater(_ video: Video, remove: Bool = false) {
        guard profile != nil else {
            loginPresented = true
            return
        }
        guard !libraryBusy.contains(video.id) else { return }
        libraryBusy.insert(video.id)
        Task {
            defer { libraryBusy.remove(video.id) }
            do {
                if remove {
                    guard let aid = video.aid else {
                        throw APIError(code: -1, message: "无法识别视频编号，请刷新列表")
                    }
                    try await api.removeFromWatchLater(aid: aid)
                    removedLater = video
                    toast = "已从稍后再看移除"
                } else {
                    try await api.addToWatchLater(bvid: video.bvid)
                    if removedLater?.id == video.id { removedLater = nil }
                    toast = "已加入稍后再看"
                }
                cachedLists.removeValue(forKey: "稍后再看")
                if menu == "稍后再看" && selected == nil { refresh() }
            } catch { toast = error.localizedDescription }
        }
    }

}
