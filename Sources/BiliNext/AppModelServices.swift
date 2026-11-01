import BiliNextCore
import Foundation

/// Shared by one workspace and its retained pages, never a process-wide singleton.
/// This object contains dependencies, not page results, playback state or UI selection.
@MainActor
final class AppModelServices {
    let account = AppAccountState()
    let api: BilibiliAPI
    let sessionStore: SessionStore
    let downloads: DownloadManager
    let hoverPreview: HoverPreview
    lazy var playbackPrefetch = PlaybackPrefetch(api: api)
    let browsePageLoader: (BrowsePageRequest) async throws -> BrowsePageResult
    let profileLoader: () async throws -> UserProfile
    let favoriteFolderLoader: (Int64) async throws -> [FavoriteFolder]
    let subtitleLoader: (SubtitleTrack) async throws -> [Cue]
    let subtitlePreferences: UserDefaults
    let historyStoreURL: URL?
    let playerFactory: () throws -> MPVPlayer

    /// Weak callbacks keep account identity and history refresh tied to the owning workspace.
    weak var owner: AppModel?
    var loadedFollowedLives: FollowedLives?
    var followedLives: FollowedLives {
        if let loadedFollowedLives { return loadedFollowedLives }
        let lives = FollowedLives(api: api)
        loadedFollowedLives = lives
        return lives
    }
    let watchLaterSynchronization = WatchLaterSynchronization()
    lazy var historyOutbox = WatchHistoryOutbox(
        store: historyStoreURL,
        activeAccount: { [weak self] in self?.owner?.profile?.id },
        send: { [api] entry in
            try await api.reportWatchProgress(
                bvid: entry.progress.bvid, cid: entry.progress.cid,
                position: entry.progress.position, expectedUserID: entry.accountID)
        },
        onSuccess: { [weak self] in
            guard let owner = self?.owner else { return }
            for history in owner.browseInstances.values where history.menu == .history {
                history.cachedLists = [:]
                if owner.selected == nil && owner.menu == .history { history.refresh() }
            }
        }, onError: { error in NSLog("Watch history outbox: %@", error.localizedDescription) })

    func updateAccountGeneration(_ generation: UUID) {
        account.updateGeneration(generation)
        loadedFollowedLives?.reset()
        owner?.publishWatchLaterBusy()
    }

    func updateProfile(_ profile: UserProfile?) {
        // Playback URLs include account-specific qualities. Clear once for the shared identity.
        if account.profile?.id != profile?.id { playbackPrefetch.removeAll() }
        account.updateProfile(profile)
    }

    init(
        sessionStore: SessionStore, downloads: DownloadManager?, api: BilibiliAPI?,
        hoverPreview: HoverPreview?,
        browsePageLoader: ((BrowsePageRequest) async throws -> BrowsePageResult)?,
        profileLoader: (() async throws -> UserProfile)?,
        favoriteFolderLoader: ((Int64) async throws -> [FavoriteFolder])?,
        subtitleLoader: ((SubtitleTrack) async throws -> [Cue])?,
        subtitlePreferences: UserDefaults, historyStoreURL: URL?,
        playerFactory: (() throws -> MPVPlayer)? = nil
    ) {
        #if DEBUG
            let resolvedAPI = api ?? BilibiliAPI(credentialStorage: .developmentFile)
        #else
            let resolvedAPI = api ?? BilibiliAPI()
        #endif
        self.api = resolvedAPI
        self.playerFactory = playerFactory ?? { try MPVPlayer() }
        self.sessionStore = sessionStore
        self.downloads = downloads ?? DownloadManager()
        self.hoverPreview = hoverPreview ?? HoverPreview(api: resolvedAPI)
        self.browsePageLoader =
            browsePageLoader ?? { request in
                try await AppModel.loadBrowsePage(request, api: resolvedAPI)
            }
        self.profileLoader = profileLoader ?? { try await resolvedAPI.profile() }
        self.favoriteFolderLoader =
            favoriteFolderLoader ?? {
                try await resolvedAPI.favoriteFolders(mid: $0)
            }
        self.subtitleLoader = subtitleLoader ?? { try await resolvedAPI.subtitles($0) }
        self.subtitlePreferences = subtitlePreferences
        // API-injected models (including offline tests) never use the user's persistent outbox.
        self.historyStoreURL =
            historyStoreURL ?? (api == nil ? WatchHistoryOutbox.defaultStoreURL : nil)
    }
}
