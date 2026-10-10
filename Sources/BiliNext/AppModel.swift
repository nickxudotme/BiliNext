import AVKit
import BiliNextCore
import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    #if DEBUG
        let api = BilibiliAPI(credentialStorage: .developmentFile)
        let credentialNotice = "开发版：本机会话文件未加密，仅当前用户可读写"
    #else
        let api = BilibiliAPI()
        let credentialNotice = "登录凭据仅保存在本机钥匙串"
    #endif
    @Published var officialCore = false
    @Published var officialPlayerStatus = ""
    weak var officialWebView: WKWebView?
    let player = AVPlayer()
    let danmaku = DanmakuModel()
    let downloads = DownloadManager()
    @Published var downloadsPresented = false
    @Published var duration = 0.0
    @Published var buffering = false
    @Published var playbackRate = 1.0
    @Published var theater = false
    @Published var menu = "动态"
    @Published var tabs: [SessionTab] = []
    @Published var selected: String?
    @Published var closed: [SessionTab] = []
    @Published var profile: UserProfile?
    @Published var query = ""
    @Published var homeSection = "推荐"
    @Published var dynamicMode = "视频"
    @Published var timelineRefresh = 0
    @Published var catalogRefresh = 0
    @Published var searchOrder = "totalrank"
    @Published var libraryQuery = ""
    @Published var favoriteOrder = "mtime"
    @Published var videos: [Video] = []
    @Published var loading = false
    @Published var browseError: String?
    @Published var hasMore = false
    @Published var folders: [FavoriteFolder] = []
    @Published var folderID: Int64 = 0
    @Published var libraryBusy = Set<String>()
    @Published var removedLater: Video?
    @Published var loginPresented = false
    @Published var toast: String?
    @Published var detail: VideoDetail?
    @Published var pageID: Int64?
    @Published var videoLoading = false
    @Published var playerError: String?
    @Published var tracks: [SubtitleTrack] = []
    @Published var trackID = ""
    @Published var cues: [Cue] = []
    @Published var subtitleError: String?
    @Published var subtitleLoading = false
    let playbackClock = PlaybackClock()
    var time: Double {
        get { playbackClock.time }
        set { playbackClock.update(newValue) }
    }
    @Published var playing = false
    @Published var quality = ""
    @Published var qualityID = 64
    @Published var qualities: [PlaybackQuality] = []
    private var qualityTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var mediaID: String?
    private var observer: Any?
    private var mediaLoader: MediaResourceLoader?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var started = false
    private var page = 1
    private var offset: String?
    private var browseGeneration = UUID()
    private var videoGeneration = UUID()
    private var subtitleGeneration = UUID()
    private var cachedLists: [String: [Video]] = [:]
    private var history = ["动态"]
    private var historyIndex = 0
    private var lastSaved = Date.distantPast
    private let sessionStore = SessionStore()

    // MARK: - Lifecycle

    init() {
        if let saved = try? sessionStore.read() {
            tabs = saved
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] value in
            Task { @MainActor in
                guard let self, !self.officialCore else { return }
                self.updatePlayback(
                    time: value.seconds, duration: self.player.currentItem?.duration.seconds ?? 0,
                    playing: self.player.rate != 0,
                    buffering: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                self.updateDanmaku()
                if Date().timeIntervalSince(self.lastSaved) > 5 {
                    self.saveSession(updateTabs: false)
                }
            }
        }
    }

    func updatePlayback(time: Double, duration: Double, playing: Bool, buffering: Bool? = nil) {
        self.time = time
        let length = duration.isFinite ? max(0, duration) : 0
        if self.duration != length { self.duration = length }
        if self.playing != playing { self.playing = playing }
        if let buffering, self.buffering != buffering { self.buffering = buffering }
    }

    func start() async {
        guard !started else { return }
        started = true
        profile = try? await api.profile()
        refresh()
    }
    // MARK: - Browsing and library

    var canBack: Bool { historyIndex > 0 }
    var canForward: Bool { historyIndex < history.count - 1 }
    func navigate(_ destination: String) {
        selected = nil
        menu = destination
        libraryQuery = ""
        history = Array(history.prefix(historyIndex + 1))
        history.append(destination)
        historyIndex += 1
        refresh()
    }
    func moveHistory(_ delta: Int) {
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        historyIndex = next
        menu = history[next]
        selected = nil
        refresh()
    }
    func refresh(more: Bool = false) {
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
                var seen = Set<String>()
                videos = ((more ? videos : []) + result).filter { seen.insert($0.id).inserted }
                cachedLists[
                    destination == "收藏" ? "收藏:\(folderID):\(libraryKeyword):\(sort)" : cacheKey] =
                    videos
                offset = next
                page = requestedPage
                hasMore = moreAvailable
            } catch {
                guard !Task.isCancelled, generation == browseGeneration else { return }
                browseError = error.localizedDescription
            }
            loading = false
        }
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

    // MARK: - Tabs and session

    func open(_ video: Video, background: Bool = false) {
        if !tabs.contains(where: { $0.id == video.id }) {
            tabs.append(
                SessionTab(
                    video: video, cid: video.historyCID, position: max(0, video.progress ?? 0)))
        }
        if background {
            toast = "已加入侧栏"
            saveSession()
        } else {
            activate(video.id)
        }
    }
    func close(_ id: String) {
        saveSession()
        closed = tabs.filter { $0.id == id }
        let index = tabs.firstIndex(where: { $0.id == id }) ?? 0
        tabs.removeAll { $0.id == id }
        if mediaID == id { stopMedia() }
        if selected == id {
            selected = nil
            if !tabs.isEmpty { activate(tabs[min(index, tabs.count - 1)].id) } else { refresh() }
        }
        saveSession()
    }
    func clearTabs() {
        saveSession()
        closed = tabs
        tabs = []
        selected = nil
        stopMedia()
        saveSession()
        refresh()
    }
    func undoClose() {
        for tab in closed where !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        closed = []
        saveSession()
    }
    func saveSession(updateTabs: Bool = true) {
        var snapshot = tabs
        if officialCore || player.currentItem?.status == .readyToPlay,
            let index = snapshot.firstIndex(where: { $0.id == mediaID })
        {
            let seconds = officialCore ? time : player.currentTime().seconds
            if seconds.isFinite { snapshot[index].position = max(0, seconds) }
            snapshot[index].cid = pageID
            if updateTabs { tabs = snapshot }
        }
        do {
            try sessionStore.write(snapshot)
            lastSaved = Date()
        } catch { toast = "标签恢复记录保存失败：\(error.localizedDescription)" }
    }

    // MARK: - Media playback

    func switchPlayer() {
        saveSession()
        player.pause()
        playing = false
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            officialCore = false
            seek(time)
        } else {
            officialCore = true
        }
    }
    func activate(_ id: String, force: Bool = false) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selected = id
        if mediaID == id && !force { return }
        saveSession()
        officialCore = false
        player.pause()
        playing = false
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        let generation = UUID()
        videoGeneration = generation
        subtitleGeneration = UUID()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        statusObserver = nil
        durationObserver = nil
        mediaID = id
        detail = nil
        pageID = nil
        cues = []
        tracks = []
        trackID = ""
        time = 0
        playerError = nil
        subtitleError = nil
        videoLoading = true
        subtitleLoading = false
        videoTask = Task {
            do {
                let source = tabs.first(where: { $0.id == id })?.video
                let loaded: VideoDetail
                if let source, source.episodeID != nil, let cid = source.historyCID {
                    loaded = VideoDetail(
                        video: source, pages: [VideoPage(cid: cid, number: 1, title: source.title)],
                        description: "番剧内容的播放权限由 B 站账号及地区授权决定。")
                } else {
                    loaded = try await api.detail(id)
                }
                guard !Task.isCancelled, generation == videoGeneration else { return }
                detail = loaded
                if let index = tabs.firstIndex(where: { $0.id == id }) {
                    tabs[index].video = loaded.video
                }
                let saved = tabs.first(where: { $0.id == id })
                guard
                    let page = loaded.pages.first(where: { $0.cid == saved?.cid })
                        ?? loaded.pages.first
                else { throw APIError(code: -1, message: "视频没有可播放的分 P") }
                pageID = page.cid
                await loadMedia(
                    id: id, cid: page.cid, position: saved?.position ?? 0, generation: generation)
            } catch {
                guard !Task.isCancelled, generation == videoGeneration else { return }
                playerError = error.localizedDescription
                videoLoading = false
            }
        }
    }
    func selectPage(_ cid: Int64) {
        guard let id = selected, cid != pageID else { return }
        saveSession()
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        subtitleGeneration = UUID()
        let generation = UUID()
        videoGeneration = generation
        pageID = cid
        time = 0
        playing = false
        cues = []
        tracks = []
        trackID = ""
        subtitleError = nil
        if let i = tabs.firstIndex(where: { $0.id == id }) {
            tabs[i].cid = cid
            tabs[i].position = 0
        }
        videoTask = Task { await loadMedia(id: id, cid: cid, position: 0, generation: generation) }
    }
    private func loadMedia(id: String, cid: Int64, position: Double, generation: UUID) async {
        videoLoading = true
        playerError = nil
        subtitleLoading = true
        duration = 0
        danmaku.configure(cid: cid)
        danmaku.update(time: position, duration: 0, api: api)
        // Subtitles are independent: media failure must not discard a readable transcript.
        subtitleTask = Task {
            do {
                let result = try await api.subtitleTracks(bvid: id, cid: cid)
                guard !Task.isCancelled, generation == videoGeneration else { return }
                tracks = result
                if let first = result.first {
                    selectTrack(first.id)
                } else {
                    subtitleLoading = false
                }
            } catch {
                guard !Task.isCancelled, generation == videoGeneration else { return }
                subtitleError = error.localizedDescription
                subtitleLoading = false
            }
        }
        do {
            let playback = try await api.playback(
                bvid: id, cid: cid, episodeID: detail?.video.episodeID)
            guard !Task.isCancelled, generation == videoGeneration else { return }
            quality = playback.quality
            qualityID = playback.qualityID
            qualities = playback.qualities
            mediaLoader?.invalidate()
            let loader = MediaResourceLoader(url: playback.url)
            mediaLoader = loader
            let item = AVPlayerItem(asset: loader.asset)
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, generation == self.videoGeneration,
                        self.player.currentItem === item
                    else { return }
                    if item.status == .failed {
                        self.playerError = item.error?.localizedDescription ?? "媒体加载失败"
                    }
                }
            }
            observeDuration(item, generation: generation)
            player.replaceCurrentItem(with: item)
            if position > 0 {
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
        } catch {
            guard !Task.isCancelled, generation == videoGeneration else { return }
            playerError = error.localizedDescription
        }
        if generation == videoGeneration { videoLoading = false }
    }
    private func observeDuration(_ item: AVPlayerItem, generation: UUID) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) {
            [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self, generation == self.videoGeneration else { return }
                if seconds.isFinite && seconds > 0 { self.duration = seconds }
            }
        }
    }
    func selectQuality(_ value: Int) {
        guard let id = mediaID, let cid = pageID, value != qualityID else { return }
        qualityTask?.cancel()
        let generation = videoGeneration
        let position = time
        let resume = playing
        player.pause()
        videoLoading = true
        playerError = nil
        qualityTask = Task { [self] in
            do {
                let result = try await api.playback(
                    bvid: id, cid: cid, quality: value, episodeID: detail?.video.episodeID)
                guard !Task.isCancelled, generation == videoGeneration else { return }
                quality = result.quality
                qualityID = result.qualityID
                qualities = result.qualities
                mediaLoader?.invalidate()
                let loader = MediaResourceLoader(url: result.url)
                mediaLoader = loader
                let item = AVPlayerItem(asset: loader.asset)
                statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, generation == self.videoGeneration,
                            self.player.currentItem === item
                        else { return }
                        if item.status == .failed {
                            self.playerError = item.error?.localizedDescription ?? "媒体加载失败"
                        }
                    }
                }
                observeDuration(item, generation: generation)
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                guard !Task.isCancelled, generation == videoGeneration else { return }
                if resume { player.playImmediately(atRate: Float(playbackRate)) }
                if result.qualityID != value { toast = "此视频当前可用清晰度为" + result.quality }
            } catch {
                if !Task.isCancelled, generation == videoGeneration {
                    playerError = error.localizedDescription
                }
            }
            if !Task.isCancelled, generation == videoGeneration { videoLoading = false }
        }
    }
    func seek(_ seconds: Double) {
        if officialCore {
            if seconds.isFinite {
                officialWebView?.evaluateJavaScript("window.biliPlayer?.seek( \(max(0, seconds)));")
            }
            return
        }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
    }
    func togglePlayback() {
        if officialCore {
            officialWebView?.evaluateJavaScript(
                "{ const p=window.biliPlayer; if(p) { if(p.isPaused()) p.play(); else p.pause(); } }"
            )
            return
        }
        if player.rate == 0 {
            player.playImmediately(atRate: Float(playbackRate))
        } else {
            player.pause()
        }
        playing = player.rate != 0
    }
    func setRate(_ value: Double) {
        playbackRate = value
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.setPlaybackRate(\(value));")
            return
        }
        if playing { player.rate = Float(value) }
    }
    func updateDanmaku() {
        guard !officialCore else { return }
        danmaku.update(time: time, duration: duration, api: api)
    }
    func isPlaying(_ id: String) -> Bool { id == mediaID && playing }
    private func stopMedia() {
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        videoGeneration = UUID()
        subtitleGeneration = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        statusObserver = nil
        durationObserver = nil
        mediaID = nil
        playing = false
        danmaku.configure(cid: nil)
        duration = 0
        buffering = false
    }

    // MARK: - Subtitles

    func selectTrack(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        subtitleTask?.cancel()
        let generation = UUID()
        subtitleGeneration = generation
        trackID = id
        cues = []
        subtitleError = nil
        subtitleLoading = true
        subtitleTask = Task {
            do {
                let result = try await api.subtitles(track)
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                cues = result
            } catch {
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                subtitleError = error.localizedDescription
            }
            subtitleLoading = false
        }
    }

    // MARK: - Login

    func loggedIn() async {
        profile = try? await api.profile()
        cachedLists.removeAll()
        folders = []
        folderID = 0
        loginPresented = false
        refresh()
    }
    func logout() async {
        do {
            try await api.logout()
            profile = nil
            cachedLists.removeAll()
            folders = []
            folderID = 0
            removedLater = nil
            videos = []
            stopMedia()
            selected = nil
            refresh()
        } catch { browseError = error.localizedDescription }
    }
}
