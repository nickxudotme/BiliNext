import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Browsing and library

    var canBack: Bool { historyIndex > 0 }
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
        history = Array(history.prefix(historyIndex + 1))
        history.append(destination)
        historyIndex += 1
        if destination == "历史" || browseInstances[destination] == nil { refresh() }
    }
    func moveHistory(_ delta: Int) {
        suspendPlaybackTabs()
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        historyIndex = next
        menu = history[next]
        selected = nil
        if menu == "历史" || browseInstances[menu] == nil { refresh() }
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
        let requestedFolder = folderID
        let libraryKeyword = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = favoriteOrder
        let searchSort = searchOrder
        let cacheKey =
            destination == "收藏"
            ? "收藏:\(requestedFolder):\(libraryKeyword):\(sort)"
            : destination == "搜索"
                ? "搜索:\(keyword):\(searchSort)"
                : destination == "首页"
                    ? "首页:\(homeSection)"
                    : destination == "历史" ? "历史:\(libraryKeyword)" : destination
        if !more {
            page = 1
            offset = nil
            videos = cachedLists[cacheKey] ?? []
            hasMore = false
        }
        browseError = nil
        if destination == "动态" && dynamicMode == "全部" {
            loading = false
            timelineRefresh += 1
            return
        }
        if destination == "首页" && homeSection == "番剧" {
            loading = false
            catalogRefresh += 1
            return
        }
        if ["动态", "收藏", "历史", "稍后再看"].contains(destination) && profile == nil {
            videos = []
            loading = false
            hasMore = false
            return
        }
        if destination == "搜索" && keyword.isEmpty {
            videos = []
            loading = false
            hasMore = false
            return
        }
        if destination == "搜索", let bvid = Video.extractBVID(keyword) {
            loading = false
            open(Video(bvid: bvid, title: bvid))
            return
        }
        loading = true
        let requestedPage = more ? page + 1 : 1
        let requestedOffset = offset
        browseTask = Task {
            do {
                let result: [Video]
                var next: String?
                var moreAvailable = false
                switch destination {
                case "动态":
                    let feed = try await api.feed(offset: more ? requestedOffset : nil)
                    result = feed.videos
                    next = feed.next
                    moreAvailable = next != nil
                case "收藏":
                    guard let mid = profile?.id else { throw APIError(code: -101, message: "请先登录") }
                    let available = try await api.favoriteFolders(mid: mid)
                    guard !Task.isCancelled, generation == browseGeneration else { return }
                    folders = available
                    let folder =
                        available.first(where: { $0.id == requestedFolder }) ?? available.first
                    folderID = folder?.id ?? 0
                    if let folder {
                        let feed = try await api.favorites(
                            folder: folder.id, page: requestedPage, keyword: libraryKeyword,
                            order: sort)
                        result = feed.videos
                        moreAvailable = feed.next != nil
                    } else {
                        result = []
                    }
                case "稍后再看":
                    let feed = try await api.watchLater(page: requestedPage)
                    result = feed.videos
                    moreAvailable = feed.next != nil
                case "历史":
                    let feed =
                        try await libraryKeyword.isEmpty
                        ? api.watchHistory(cursor: more ? requestedOffset : nil)
                        : api.searchHistory(keyword: libraryKeyword, page: requestedPage)
                    result = feed.videos
                    next = feed.next
                    moreAvailable = next != nil
                case "搜索":
                    result = try await api.search(keyword, page: requestedPage, order: searchSort)
                    moreAvailable = !result.isEmpty
                default:
                    if homeSection == "排行榜" {
                        result = try await api.ranking()
                    } else if homeSection == "热门" {
                        result = try await api.popular(page: requestedPage)
                        moreAvailable = !result.isEmpty
                    } else {
                        result = try await api.recommended(page: requestedPage)
                        moreAvailable = !result.isEmpty
                    }
                }
                guard !Task.isCancelled, generation == browseGeneration else { return }
                let previousCount = videos.count
                var seen = Set<String>()
                videos = ((more ? videos : []) + result).filter { seen.insert($0.id).inserted }
                cachedLists[
                    destination == "收藏" ? "收藏:\(folderID):\(libraryKeyword):\(sort)" : cacheKey] =
                    videos
                offset = next
                page = requestedPage
                hasMore = moreAvailable
                if more && videos.count == previousCount && (next == nil || next == requestedOffset)
                {
                    hasMore = false
                }
            } catch {
                guard !Task.isCancelled, generation == browseGeneration else { return }
                browseError = error.localizedDescription
            }
            loading = false
        }
    }
    func loadMoreIfNeeded() {
        guard selected == nil, hasMore, !loading, browseError == nil, !videos.isEmpty else {
            return
        }
        refresh(more: true)
    }
    func selectFolder(_ id: Int64) {
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
