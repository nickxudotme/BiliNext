import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    let api: BilibiliAPI
    let hoverPreview: HoverPreview
    #if DEBUG
        let credentialNotice = "开发版：本机会话文件未加密，仅当前用户可读写"
    #else
        let credentialNotice = "登录凭据仅保存在本机钥匙串"
    #endif
    @Published var officialCore = false
    @Published var officialPlayerStatus = ""
    weak var officialWebView: WKWebView?
    let player = AVPlayer()
    @Published private(set) var mpv: MPVPlayer?
    private var awaitingMPVLoad = false
    var playerVolume: Double {
        get { mpv?.volume ?? Double(player.volume) }
        set { if let mpv { mpv.volume = newValue } else { player.volume = Float(newValue) } }
    }
    let danmaku = DanmakuModel()
    let downloads: DownloadManager
    @Published private(set) var playbackInstances: [String: AppModel] = [:]
    @Published private(set) var browseInstances: [String: AppModel] = [:]
    private(set) var playbackTabActive = true
    private weak var tabOwner: AppModel?
    private let managesPlaybackTabs: Bool
    private var tabSubscriptions: [String: Set<AnyCancellable>] = [:]
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
    private(set) var playbackCodec = ""
    @Published var qualities: [PlaybackQuality] = []
    private var qualityTask: Task<Void, Never>?
    private var qualitySwitchState: (position: Double, resume: Bool)?
    private var playbackIntent = false
    private var failedCodecItem: ObjectIdentifier?
    private var browseTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var mediaID: String?
    private var observer: Any?
    private var mediaLoader: MediaResourceLoader?
    private var dashLoader: DASHResourceLoader?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var started = false
    private var page = 1
    private var offset: String?
    private var browseGeneration = UUID()
    private var videoGeneration = UUID()
    private var subtitleGeneration = UUID()
    private var qualityGeneration = UUID()
    private var cachedLists: [String: [Video]] = [:]
    private var history = ["动态"]
    private var historyIndex = 0
    private var lastSaved = Date.distantPast
    private let sessionStore: SessionStore

    // MARK: - Lifecycle

    init(
        sessionStore: SessionStore = SessionStore(), managesPlaybackTabs: Bool = true,
        downloads: DownloadManager? = nil, api: BilibiliAPI? = nil,
        hoverPreview: HoverPreview? = nil
    ) {
        #if DEBUG
            self.api = api ?? BilibiliAPI(credentialStorage: .developmentFile)
        #else
            self.api = api ?? BilibiliAPI()
        #endif
        self.hoverPreview = hoverPreview ?? HoverPreview(api: self.api)
        self.sessionStore = sessionStore
        self.managesPlaybackTabs = managesPlaybackTabs
        self.downloads = downloads ?? DownloadManager()
        if managesPlaybackTabs, let saved = try? sessionStore.read() {
            tabs = saved
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] value in
            Task { @MainActor in
                guard let self, !self.officialCore, self.mpv == nil else { return }
                self.updatePlayback(
                    time: value.seconds, duration: self.player.currentItem?.duration.seconds ?? 0,
                    playing: self.player.rate != 0,
                    buffering: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                if self.playbackTabActive { self.updateDanmaku() }
                if self.playbackTabActive && Date().timeIntervalSince(self.lastSaved) > 5 {
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
        if browseInstances[destination] == nil { refresh() }
    }
    func moveHistory(_ delta: Int) {
        suspendPlaybackTabs()
        let next = historyIndex + delta
        guard history.indices.contains(next) else { return }
        historyIndex = next
        menu = history[next]
        selected = nil
        if browseInstances[menu] == nil { refresh() }
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

    // MARK: - Tabs and session

    func open(_ video: Video, background: Bool = false) {
        if let tabOwner {
            tabOwner.open(video, background: background)
            return
        }
        if !tabs.contains(where: { $0.id == video.id }) {
            tabs.append(
                SessionTab(
                    video: video, cid: video.historyCID, position: max(0, video.progress ?? 0)))
        }
        if background {
            toast = "已加入侧栏"
            saveSession()
        } else {
            activate(video.id, autoplay: true)
        }
    }
    func close(_ id: String) {
        saveSession()
        closed = tabs.filter { $0.id == id }
        let index = tabs.firstIndex(where: { $0.id == id }) ?? 0
        tabs.removeAll { $0.id == id }
        releasePlaybackTab(id)
        if mediaID == id { stopMedia() }
        if selected == id {
            selected = nil
            if !tabs.isEmpty {
                activate(tabs[min(index, tabs.count - 1)].id)
            } else if browseInstances[menu] == nil {
                refresh()
            }
        }
        saveSession()
    }
    func clearTabs() {
        saveSession()
        if let selected, tabs.contains(where: { $0.id == selected }) {
            closed = tabs.filter { $0.id != selected }
            for tab in closed { releasePlaybackTab(tab.id) }
            tabs.removeAll { $0.id != selected }
            saveSession()
        } else {
            closed = tabs
            for tab in closed { releasePlaybackTab(tab.id) }
            tabs = []
            selected = nil
            stopMedia()
            saveSession()
            if browseInstances[menu] == nil { refresh() }
        }
    }
    func undoClose() {
        for tab in closed where !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        closed = []
        saveSession()
    }
    func saveSession(updateTabs: Bool = true) {
        if let tabOwner {
            tabOwner.saveSession(updateTabs: updateTabs)
            return
        }
        var snapshot = tabs
        for index in snapshot.indices {
            guard let instance = playbackInstances[snapshot[index].id] else { continue }
            if let video = instance.detail?.video { snapshot[index].video = video }
            snapshot[index].cid = instance.pageID ?? snapshot[index].cid
            let seconds =
                instance.officialCore
                ? instance.time : instance.mpv?.time ?? instance.player.currentTime().seconds
            if instance.officialCore || instance.mpv?.loaded == true
                || instance.player.currentItem?.status == .readyToPlay,
                seconds.isFinite
            {
                snapshot[index].position = max(0, seconds)
            }
        }
        if updateTabs { tabs = snapshot }
        if officialCore || mpv?.loaded == true || player.currentItem?.status == .readyToPlay,
            let index = snapshot.firstIndex(where: { $0.id == mediaID })
        {
            let seconds = officialCore ? time : (mpv?.time ?? player.currentTime().seconds)
            if seconds.isFinite { snapshot[index].position = max(0, seconds) }
            snapshot[index].cid = pageID
            if updateTabs { tabs = snapshot }
        }
        do {
            try sessionStore.write(snapshot)
            lastSaved = Date()
            for instance in playbackInstances.values { instance.lastSaved = lastSaved }
        } catch { toast = "标签恢复记录保存失败：\(error.localizedDescription)" }
    }

    private func suspendPlaybackTabs(except id: String? = nil) {
        for (key, instance) in playbackInstances where key != id {
            instance.playbackTabActive = false
            if let state = instance.qualitySwitchState {
                instance.qualitySwitchState = (state.position, false)
            }
            instance.player.pause()
            instance.mpv?.pause()
            instance.officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            instance.playbackIntent = false
            instance.playing = false
        }
    }

    private func releasePlaybackTab(_ id: String) {
        playbackInstances[id]?.officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
        playbackInstances[id]?.stopMedia()
        if let instance = playbackInstances[id], let observer = instance.observer {
            instance.player.removeTimeObserver(observer)
            instance.observer = nil
        }
        playbackInstances.removeValue(forKey: id)
        tabSubscriptions.removeValue(forKey: id)
    }

    private func connectPage(_ instance: AppModel, key: String) {
        instance.tabOwner = self
        instance.profile = profile
        var subscriptions = Set<AnyCancellable>()
        instance.$loginPresented.dropFirst().sink { [weak self] value in
            if value { self?.loginPresented = true }
        }.store(in: &subscriptions)
        instance.$downloadsPresented.dropFirst().sink { [weak self] value in
            if value { self?.downloadsPresented = true }
        }.store(in: &subscriptions)
        instance.$toast.dropFirst().sink { [weak self] value in
            if let value { self?.toast = value }
        }.store(in: &subscriptions)
        instance.$playing.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        tabSubscriptions[key] = subscriptions
    }

    func browseInstance(for destination: String) -> AppModel {
        if let existing = browseInstances[destination] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview)
        instance.menu = destination
        connectPage(instance, key: "browse:" + destination)
        browseInstances[destination] = instance
        return instance
    }

    func playbackInstance(for tab: SessionTab) -> AppModel {
        if let existing = playbackInstances[tab.id] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview)
        instance.tabs = [tab]
        instance.menu = menu
        connectPage(instance, key: tab.id)
        playbackInstances[tab.id] = instance
        return instance
    }

    private func activatePlaybackTab(_ id: String, force: Bool, autoplay: Bool) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        hoverPreview.stop()
        saveSession()
        suspendPlaybackTabs(except: id)
        let instance = playbackInstance(for: tab)
        selected = id
        instance.profile = profile
        instance.playbackTabActive = true
        instance.activate(id, force: force, autoplay: autoplay)
    }

    // MARK: - Media playback

    func switchPlayer() {
        saveSession()
        mpv?.pause()
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
    func activate(_ id: String, force: Bool = false, autoplay: Bool = false) {
        if managesPlaybackTabs {
            activatePlaybackTab(id, force: force, autoplay: autoplay)
            return
        }
        guard tabs.contains(where: { $0.id == id }) else { return }
        selected = id
        if mediaID == id && !force {
            if autoplay {
                if officialCore {
                    officialWebView?.evaluateJavaScript("window.biliPlayer?.play()")
                } else {
                    playbackIntent = true
                    startBufferedPlayback()
                }
            }
            return
        }
        saveSession()
        officialCore = false
        mpv?.pause()
        player.pause()
        playing = false
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        let generation = UUID()
        videoGeneration = generation
        subtitleGeneration = UUID()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
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
                    id: id, cid: page.cid, position: saved?.position ?? 0, generation: generation,
                    autoplay: autoplay)
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
        mpv?.pause()
        player.pause()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
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
    private func loadMedia(
        id: String, cid: Int64, position: Double, generation: UUID, autoplay: Bool = false
    ) async {
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
            let source = try await api.playback(
                bvid: id, cid: cid, quality: 80, episodeID: detail?.video.episodeID)
            guard !Task.isCancelled, generation == videoGeneration else { return }
            let core = try ensureMPV()
            quality = source.quality
            qualityID = source.qualityID
            playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
            qualities = source.qualities
            playbackIntent = autoplay && playbackTabActive
            core.speed = playbackRate
            awaitingMPVLoad = true
            try core.load(source, position: position, autoplay: playbackIntent)
        } catch {
            guard !Task.isCancelled, generation == videoGeneration else { return }
            playerError = error.localizedDescription
            videoLoading = false
        }
    }

    private func ensureMPV() throws -> MPVPlayer {
        if let mpv { return mpv }
        let core = try MPVPlayer()
        core.muted = player.isMuted || CommandLine.arguments.contains("--mute")
        core.volume = Double(player.volume)
        core.onUpdate = { [weak self, weak core] time, duration, playing, buffering in
            guard let self, let core, !self.officialCore else { return }
            self.updatePlayback(
                time: time, duration: duration, playing: playing, buffering: buffering)
            if self.awaitingMPVLoad && core.loaded {
                self.awaitingMPVLoad = false
                self.videoLoading = false
            }
            if let failure = core.failure {
                self.playerError = failure
                self.videoLoading = false
            }
            if self.playbackTabActive { self.updateDanmaku() }
            if core.loaded && self.playbackTabActive && Date().timeIntervalSince(self.lastSaved) > 5
            {
                self.saveSession(updateTabs: false)
            }
        }
        mpv = core
        return core
    }

    private func loadAVMedia(
        id: String, cid: Int64, position: Double, generation: UUID, autoplay: Bool
    ) async {
        do {
            let (playback, item) = try await playableMedia(id: id, cid: cid, quality: 80)
            guard !Task.isCancelled, generation == videoGeneration else { return }
            quality = playback.quality
            qualityID = playback.qualityID
            playbackCodec = playback.videoStream?.codec ?? "MP4"
            qualities = playback.qualities
            playbackIntent = autoplay && playbackTabActive
            observeMediaStatus(item, playback: playback, generation: generation)
            observeDuration(item, generation: generation)
            player.replaceCurrentItem(with: item)
            if position > 0 {
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            guard !Task.isCancelled, generation == videoGeneration, selected == id,
                player.currentItem === item
            else { return }
            if autoplay && playbackTabActive { startBufferedPlayback() }
        } catch {
            guard !Task.isCancelled, generation == videoGeneration else { return }
            playerError = error.localizedDescription
        }
        if generation == videoGeneration { videoLoading = false }
    }
    private func playableMedia(
        id: String, cid: Int64, quality: Int,
        allowAV1: Bool = true, allowHEVC: Bool = true
    ) async throws -> (Playback, AVPlayerItem) {
        var result = try await api.playback(
            bvid: id, cid: cid, quality: quality,
            episodeID: detail?.video.episodeID, allowAV1: allowAV1, allowHEVC: allowHEVC)
        while true {
            try Task.checkCancellation()
            do { return (result, try await prepareMedia(result)) } catch {
                try Task.checkCancellation()
                guard let stream = result.videoStream else { throw error }
                let isAV1 = stream.codec.hasPrefix("av01.")
                let isHEVC = stream.codec.hasPrefix("hev1") || stream.codec.hasPrefix("hvc1")
                if isAV1 || isHEVC {
                    result = try await api.playback(
                        bvid: id, cid: cid, quality: quality,
                        episodeID: detail?.video.episodeID, allowAV1: false, allowHEVC: isAV1)
                    continue
                }
                let fallback = try await api.playback(
                    bvid: id, cid: cid, quality: quality,
                    episodeID: detail?.video.episodeID, preferDASH: false)
                let item = try await prepareMedia(fallback)
                try Task.checkCancellation()
                toast = "分离流暂时无法加载，已回退到 " + fallback.quality
                return (fallback, item)
            }
        }
    }

    func observeMediaStatus(_ item: AVPlayerItem, playback: Playback, generation: UUID? = nil) {
        let generation = generation ?? videoGeneration
        failedCodecItem = nil
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.officialCore, generation == self.videoGeneration,
                    self.player.currentItem === item, item.status == .failed,
                    self.failedCodecItem != ObjectIdentifier(item)
                else { return }
                self.failedCodecItem = ObjectIdentifier(item)
                let codec = playback.videoStream?.codec ?? ""
                let isAV1 = codec.hasPrefix("av01.")
                let isHEVC = codec.hasPrefix("hev1") || codec.hasPrefix("hvc1")
                if isAV1 || isHEVC {
                    let current = self.player.currentTime().seconds
                    self.qualitySwitchState =
                        self.qualitySwitchState
                        ?? (current.isFinite ? current : self.time, self.playbackIntent)
                    self.toast = isAV1 ? "AV1 加载失败，正在尝试 HEVC／H.264" : "HEVC 加载失败，正在尝试 H.264"
                    self.changeQuality(
                        self.qualityID, allowAV1: false, allowHEVC: isAV1, force: true)
                } else {
                    self.playerError = item.error?.localizedDescription ?? "媒体加载失败"
                }
            }
        }
    }

    private func prepareMedia(_ playback: Playback) async throws -> AVPlayerItem {
        if playback.videoStream != nil {
            let (loader, item) = try await DASHResourceLoader.prepare(playback)
            if Task.isCancelled {
                loader.invalidate()
                throw CancellationError()
            }
            mediaLoader?.invalidate()
            mediaLoader = nil
            dashLoader?.invalidate()
            dashLoader = loader
            item.preferredForwardBufferDuration = 15
            return item
        }
        dashLoader?.invalidate()
        dashLoader = nil
        mediaLoader?.invalidate()
        let loader = MediaResourceLoader(url: playback.url)
        mediaLoader = loader
        let item = AVPlayerItem(asset: loader.asset)
        item.preferredForwardBufferDuration = 15
        return item
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
    func selectQuality(_ value: Int) { changeQuality(value) }

    private func changeQuality(
        _ value: Int, allowAV1: Bool = true, allowHEVC: Bool = true,
        force: Bool = false
    ) {
        guard let id = mediaID, let cid = pageID, force || value != qualityID || videoLoading else {
            return
        }
        qualityTask?.cancel()
        let generation = videoGeneration
        let request = UUID()
        qualityGeneration = request
        let current = mpv?.time ?? player.currentTime().seconds
        let position = qualitySwitchState?.position ?? (current.isFinite ? current : time)
        let resume = qualitySwitchState?.resume ?? (mpv?.playing ?? (player.rate != 0))
        qualitySwitchState = (position, resume)
        playbackIntent = resume
        mpv?.pause()
        player.pause()
        videoLoading = true
        playerError = nil
        qualityTask = Task { [self] in
            do {
                if let mpv {
                    let source = try await api.playback(
                        bvid: id, cid: cid, quality: value, episodeID: detail?.video.episodeID)
                    guard !Task.isCancelled, generation == videoGeneration,
                        request == qualityGeneration
                    else { return }
                    quality = source.quality
                    qualityID = source.qualityID
                    qualities = source.qualities
                    playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
                    awaitingMPVLoad = true
                    try mpv.load(source, position: position, autoplay: resume && playbackTabActive)
                    qualitySwitchState = nil
                    return
                }
                let (result, item) = try await playableMedia(
                    id: id, cid: cid, quality: value,
                    allowAV1: allowAV1, allowHEVC: allowHEVC)
                guard !Task.isCancelled, generation == videoGeneration, request == qualityGeneration
                else { return }
                quality = result.quality
                qualityID = result.qualityID
                playbackCodec = result.videoStream?.codec ?? "MP4"
                qualities = result.qualities
                observeMediaStatus(item, playback: result, generation: generation)
                observeDuration(item, generation: generation)
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                guard !Task.isCancelled, generation == videoGeneration, request == qualityGeneration
                else { return }
                if resume && playbackTabActive {
                    startBufferedPlayback()
                }
                if result.qualityID != value {
                    toast = "请求的清晰度未返回，当前使用" + result.quality + "。当前取流格式或账号权限可能受限。"
                }
            } catch {
                if !Task.isCancelled, generation == videoGeneration, request == qualityGeneration {
                    playerError = error.localizedDescription
                }
            }
            if !Task.isCancelled, generation == videoGeneration, request == qualityGeneration {
                videoLoading = false
                qualitySwitchState = nil
            }
        }
    }
    func seek(_ seconds: Double) {
        if officialCore {
            if seconds.isFinite {
                officialWebView?.evaluateJavaScript("window.biliPlayer?.seek( \(max(0, seconds)));")
            }
            return
        }
        if let mpv {
            mpv.seek(seconds)
            return
        }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
    }
    /// Let AVPlayer build a safety buffer and resume automatically after network stalls.
    func startBufferedPlayback() {
        if let mpv {
            mpv.speed = playbackRate
            mpv.play()
            return
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = Float(playbackRate)
        player.play()
    }

    func togglePlayback() {
        if managesPlaybackTabs {
            if let selected { playbackInstances[selected]?.togglePlayback() }
            return
        }
        if officialCore {
            officialWebView?.evaluateJavaScript(
                "{ const p=window.biliPlayer; if(p) { if(p.isPaused()) p.play(); else p.pause(); } }"
            )
            return
        }
        if let mpv {
            playbackIntent = !playbackIntent
            if playbackIntent { mpv.play() } else { mpv.pause() }
            playing = playbackIntent
            return
        }
        if playbackIntent || player.timeControlStatus != .paused {
            mpv?.pause()
            player.pause()
            playbackIntent = false
        } else {
            playbackIntent = true
            startBufferedPlayback()
        }
        playing = playbackIntent
    }
    func setRate(_ value: Double) {
        playbackRate = value
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.setPlaybackRate(\(value));")
            return
        }
        mpv?.speed = value
        if mpv == nil && playing { player.rate = Float(value) }
    }
    func updateDanmaku() {
        guard !officialCore else { return }
        danmaku.update(time: time, duration: duration, api: api)
    }
    func isPlaying(_ id: String) -> Bool {
        if managesPlaybackTabs { return playbackInstances[id]?.playing ?? false }
        return id == mediaID && playing
    }
    private func stopMedia() {
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        videoGeneration = UUID()
        subtitleGeneration = UUID()
        mpv?.pause()
        player.pause()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
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
        for instance in Array(playbackInstances.values) + Array(browseInstances.values) {
            instance.profile = profile
        }
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
            for destination in browseInstances.keys {
                tabSubscriptions.removeValue(forKey: "browse:" + destination)
            }
            browseInstances.removeAll()
            cachedLists.removeAll()
            folders = []
            folderID = 0
            removedLater = nil
            videos = []
            for id in Array(playbackInstances.keys) { releasePlaybackTab(id) }
            stopMedia()
            selected = nil
            refresh()
        } catch { browseError = error.localizedDescription }
    }
}
