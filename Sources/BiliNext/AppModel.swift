import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

@MainActor
final class AppModel: ObservableObject {
    // Shared dependencies have one identity for the workspace and all retained pages.
    let services: AppModelServices
    let scope: AppModelScope
    var api: BilibiliAPI { services.api }
    /// Retained by the video page, independently of the selected details panel.
    var commentInteractionState: CommentInteractionModel?
    var commentListState: (context: CommentInteractionModel.Context?, loader: CommentPageLoader)?
    // Account services are shared; page-local playback and comment state stay here.
    var followedLives: FollowedLives { services.followedLives }
    @Published var liveSession: LiveSession?
    /// The system Now Playing bridge; only the workspace owns one.
    var nowPlaying: NowPlaying?
    /// Set when this tab shows an uploader's space page instead of media.
    @Published var memberSpace: MemberSpace?
    lazy var watchHistoryReporter = WatchHistoryReporter(
        send: { [outbox = historyOutbox] progress in
            guard let account = progress.accountID else { return }
            outbox.enqueue(progress, accountID: account)
        },
        onError: { error in
            NSLog("Watch history sync failed: %@", error.localizedDescription)
        }, account: { [weak self] in self?.profile?.id })
    var historyStoreURL: URL? { services.historyStoreURL }
    var historyOutbox: WatchHistoryOutbox { services.historyOutbox }
    var hoverPreview: HoverPreview { services.hoverPreview }
    #if DEBUG
        let credentialNotice = "开发版：本机会话文件未加密，仅当前用户可读写"
    #else
        let credentialNotice = "登录凭据仅保存在本机钥匙串"
    #endif
    @Published var officialCore = false
    @Published var officialPlayerStatus = ""
    weak var officialWebView: WKWebView?
    let player = AVPlayer()
    @Published var mpv: MPVPlayer?
    var awaitingMPVLoad = false
    /// Set once the end of the current media has been acted on, until it plays again.
    var endHandled = false
    /// Timing of the current video's startup, until its first frame plays.
    var startup: PlaybackStartup?
    var playbackRecovery: PlaybackRecovery?
    var recoveryPosition = 0.0
    var recoveryGeneration = UUID()
    var playerVolume: Double {
        get { mpv?.volume ?? Double(player.volume) }
        set { if let mpv { mpv.volume = newValue } else { player.volume = Float(newValue) } }
    }
    let danmaku = DanmakuModel()
    var downloads: DownloadManager { services.downloads }
    @Published var playbackInstances: [String: AppModel] = [:]
    @Published var browseInstances: [String: AppModel] = [:]
    var playbackTabActive = true {
        didSet { mpv?.isForeground = playbackTabActive }
    }
    weak var tabOwner: AppModel?
    var managesPlaybackTabs: Bool { scope == .workspace }
    var tabSubscriptions: [String: Set<AnyCancellable>] = [:]
    var tabLoadStarted = false
    var tabPreloadsEnabled = false
    var tabPreloadQueue: [String] = []
    var tabPreloadJobs: [String: TabPreloadJob] = [:]
    @Published var downloadsPresented = false
    @Published var duration = 0.0
    @Published var buffering = false
    @Published var playbackRate = PlaybackPreferences.current.rate
    @Published var theater = false
    @Published var menu = BrowseDestination.dynamic
    @Published var tabs: [SessionTab] = []
    @Published var selected: String?
    @Published var closed: [SessionTab] = []
    /// Tabs opened in the background and not yet visited, marked in the sidebar.
    @Published var unseenTabs = Set<String>()
    @Published var sidebarPinned = true
    /// Window floats above other apps (置顶).
    @Published var windowPinned = false
    /// Window shrinks to a floating corner player (小窗) showing only the current video.
    @Published var miniPlayer = false
    var stateBeforeMiniPlayer: (sidebarPinned: Bool, windowPinned: Bool)?
    var profile: UserProfile? {
        get { services.account.profile }
        set { services.updateProfile(newValue) }
    }
    var playbackPrefetch: PlaybackPrefetch { services.playbackPrefetch }
    var accountGeneration: UUID {
        get { services.account.generation }
        set {
            services.updateAccountGeneration(newValue)
        }
    }
    private var accountSubscription: AnyCancellable?
    @Published var query = ""
    @Published var homeSection = "推荐"
    @Published var dynamicMode = "视频"
    @Published var timelineRefresh = 0
    @Published var catalogRefresh = 0
    @Published var searchOrder = "totalrank"
    @Published var libraryQuery = ""
    @Published var favoriteOrder = "mtime"
    @Published var videos: [Video] = []
    @Published var browseRevision = 0
    @Published var loading = false
    @Published var browseError: String?
    @Published var hasMore = false
    @Published var folders: [FavoriteFolder] = []
    @Published var favoriteFoldersLoading = false
    @Published var favoriteFoldersError: String?
    var favoriteFoldersTask: Task<Void, Never>?
    var favoriteFoldersAccountID: Int64?
    var favoriteFoldersGeneration = UUID()
    var favoriteFolderLoader: (Int64) async throws -> [FavoriteFolder] {
        services.favoriteFolderLoader
    }
    @Published var folderID: Int64 = 0
    @Published var libraryBusy = Set<String>()
    var watchLaterSynchronization: WatchLaterSynchronization { services.watchLaterSynchronization }
    @Published var removedLater: Video?
    @Published var loginPresented = false
    /// A transient notice. It clears itself after a few seconds, independent of any view.
    @Published var toast: String? {
        didSet {
            toastExpiry?.cancel()
            guard toast != nil else { return }
            toastExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { self?.toast = nil }
            }
        }
    }
    private var toastExpiry: Task<Void, Never>?
    @Published var detail: VideoDetail?
    @Published var pageID: Int64?
    @Published var videoLoading = false
    @Published var playerError: String?
    @Published var tracks: [SubtitleTrack] = []
    @Published var trackID = ""
    @Published var cues: [Cue] = []
    @Published var secondaryTrackID = ""
    @Published var secondaryCues: [Cue] = []
    @Published var secondarySubtitleLoading = false
    @Published var secondarySubtitleError: String?
    var secondarySubtitleTask: Task<Void, Never>?
    var secondarySubtitleGeneration = UUID()
    var subtitleLoader: (SubtitleTrack) async throws -> [Cue] { services.subtitleLoader }
    @Published var subtitleError: String?
    @Published var subtitleLoading = false
    let smartSubtitles: SmartSubtitleModel
    let playbackClock = PlaybackClock()
    var time: Double {
        get { playbackClock.time }
        set { playbackClock.update(newValue) }
    }
    @Published var playing = false
    @Published var quality = ""
    @Published var qualityID = 64
    var playbackCodec = ""
    @Published var qualities: [PlaybackQuality] = []
    @Published var highEnergy: HighEnergyCurve?
    /// The current part's 看点 chapters, empty when the uploader marked none.
    @Published var viewPoints: [ViewPoint] = []
    /// The current part's scrubber preview frames.
    @Published var videoShots: VideoShots?
    @Published var relation = VideoRelation()
    var relationLoaded = false
    /// Which video `relation` describes, and the newest read or write that may set it.
    var relationVideo: String?
    var relationGeneration = UUID()
    var relationReading = false
    @Published var interactionBusy = false
    @Published var coinDialogPresented = false
    @Published var favoritePresented = false
    /// Bumped after 一键三连 succeeds so the three action icons bounce together.
    @Published var tripleCount = 0
    var qualityTask: Task<Void, Never>?
    var qualitySwitchState: (position: Double, resume: Bool)?
    var playbackIntent = false
    var browseTask: Task<Void, Never>?
    var browsePageLoader: (BrowsePageRequest) async throws -> BrowsePageResult {
        services.browsePageLoader
    }
    var profileLoader: () async throws -> UserProfile { services.profileLoader }
    var browseLoadAttempted = false
    var browseContext: BrowsePageRequest?
    var browseRequestedOffsets = Set<String>()
    var browseRetryMore = false
    var videoTask: Task<Void, Never>?
    var subtitleTask: Task<Void, Never>?
    var mediaID: String?
    var observer: Any?
    private var started = false
    var page = 1
    var offset: String?
    var browseGeneration = UUID()
    var videoGeneration = UUID()
    var subtitleGeneration = UUID()
    var qualityGeneration = UUID()
    var cachedLists: [String: [Video]] = [:]
    var history = ["动态:视频"]
    var historyIndex = 0
    var lastSaved = Date.distantPast
    var sessionStore: SessionStore { services.sessionStore }

    // MARK: - Lifecycle

    convenience init(
        sessionStore: SessionStore = SessionStore(), managesPlaybackTabs: Bool = true,
        downloads: DownloadManager? = nil, api: BilibiliAPI? = nil,
        hoverPreview: HoverPreview? = nil,
        browsePageLoader: ((BrowsePageRequest) async throws -> BrowsePageResult)? = nil,
        profileLoader: (() async throws -> UserProfile)? = nil,
        favoriteFolderLoader: ((Int64) async throws -> [FavoriteFolder])? = nil,
        subtitleLoader: ((SubtitleTrack) async throws -> [Cue])? = nil,
        subtitlePreferences: UserDefaults = .standard, historyStoreURL: URL? = nil,
        playerFactory: (() throws -> MPVPlayer)? = nil
    ) {
        let services = AppModelServices(
            sessionStore: sessionStore, downloads: downloads, api: api,
            hoverPreview: hoverPreview, browsePageLoader: browsePageLoader,
            profileLoader: profileLoader, favoriteFolderLoader: favoriteFolderLoader,
            subtitleLoader: subtitleLoader, subtitlePreferences: subtitlePreferences,
            historyStoreURL: historyStoreURL, playerFactory: playerFactory)
        self.init(scope: managesPlaybackTabs ? .workspace : .page, services: services)
    }

    init(scope: AppModelScope, services: AppModelServices) {
        self.scope = scope
        self.services = services
        self.smartSubtitles = SmartSubtitleModel(defaults: services.subtitlePreferences)
        if scope == .workspace, let saved = try? services.sessionStore.read() {
            tabs = saved
        }
        if services.owner == nil { services.owner = self }
        accountSubscription = services.account.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] value in
            Task { @MainActor in
                guard let self, !self.officialCore, self.mpv == nil, self.liveSession == nil else {
                    return
                }
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
        if !officialCore, profile != nil, let mediaID, let pageID, detail?.video.episodeID == nil {
            watchHistoryReporter.update(
                bvid: mediaID, cid: pageID, position: time,
                playing: playing, buffering: buffering ?? self.buffering)
        }
        smartSubtitles.configure(
            video: mediaID, cid: pageID, owner: detail?.video.ownerID,
            track: tracks.first { $0.id == trackID }?.language ?? "")
        smartSubtitles.updateAvailability(hasCues: !cues.isEmpty, loading: subtitleLoading)
        smartSubtitles.sample(
            player: mpv, cues: cues,
            time: time,
            active: secondaryTrackID.isEmpty && playbackTabActive && !officialCore && playing
                && !(buffering ?? self.buffering))
        self.time = time
        let length = duration.isFinite ? max(0, duration) : 0
        if self.duration != length { self.duration = length }
        if self.playing != playing { self.playing = playing }
        if let buffering, self.buffering != buffering { self.buffering = buffering }
    }

    func start() async {
        guard !started else { return }
        started = true
        if managesPlaybackTabs && nowPlaying == nil {
            nowPlaying = NowPlaying(workspace: self)
            DNSWarmup.keepMirrorWarm()
        }
        let account = accountGeneration
        let loadedProfile = try? await profileLoader()
        guard account == accountGeneration else { return }
        profile = loadedProfile
        preloadFavoriteFolders()
        historyOutbox.accountChanged()
        startTabPreloads()
        guard selected == nil else { return }
        #if DEBUG
            // Visual checks of the playback page without clicking: opens the first restored
            // tab paused, which is not a viewing event and reports no watch history.
            if ProcessInfo.processInfo.environment["BILINEXT_DEBUG_OPEN_FIRST_TAB"] == "1",
                let first = tabs.first
            {
                activate(first.id)
                return
            }
            // Opens a video paused in a new tab, as above; it stays in the restored session.
            if let bvid = ProcessInfo.processInfo.environment["BILINEXT_DEBUG_OPEN_VIDEO"] {
                if !tabs.contains(where: { $0.id == bvid }) {
                    tabs.append(SessionTab(video: Video(bvid: bvid, title: bvid)))
                }
                activate(bvid)
                return
            }
            // Opens an uploader's space page, which plays nothing, for the same checks.
            if let value = ProcessInfo.processInfo.environment["BILINEXT_DEBUG_OPEN_SPACE"],
                let mid = Int64(value)
            {
                openSpace(mid: mid, name: "UP 主")
                return
            }
        #endif
        loadBrowseIfNeeded()
    }
}
