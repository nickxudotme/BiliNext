import AppKit
import BiliNextCore
import MediaPlayer

/// Publishes the selected tab to the system's Now Playing (Control Center, the menu bar
/// widget, media keys and headphone buttons) and routes its remote commands back.
@MainActor
final class NowPlaying {
    /// What the system shows for the selected tab.
    struct Item: Equatable {
        var title: String
        var artist: String
        var album: String?
        var cover: URL?
        var duration: Double
        var elapsed: Double
        var rate: Double
        var playing: Bool
        var live: Bool
        var hasPreviousPage: Bool
        var hasNextPage: Bool
    }

    private weak var workspace: AppModel?
    private var timer: Timer?
    private var published: Item?
    private var artwork: (url: URL, value: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    private var targets: [(MPRemoteCommand, Any)] = []

    init(workspace: AppModel) {
        self.workspace = workspace
        registerCommands()
        // Elapsed time lives outside the published state, so it is sampled rather than
        // observed; the system extrapolates between samples from the playback rate.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        for (command, target) in targets { command.removeTarget(target) }
    }

    /// The selected tab's media, or nil when it has none to show.
    static func item(for workspace: AppModel) -> Item? {
        guard let id = workspace.selected, let page = workspace.playbackInstances[id] else {
            return nil
        }
        if let session = page.liveSession {
            let room = session.room
            return Item(
                title: room?.title ?? page.tabs.first?.video.title ?? "直播",
                artist: room?.author ?? page.tabs.first?.video.author ?? "",
                cover: (room?.cover).flatMap(URL.init(string:)) ?? page.tabs.first?.video.cover,
                duration: 0, elapsed: 0, rate: session.playing ? 1 : 0, playing: session.playing,
                live: true, hasPreviousPage: false, hasNextPage: false)
        }
        guard let detail = page.detail else { return nil }
        let pages = detail.pages
        let index = pages.firstIndex { $0.cid == page.pageID }
        let part = index.flatMap { pages.count > 1 ? pages[$0].title : nil }
        return Item(
            title: detail.video.title, artist: detail.video.author,
            album: part.map { "P\(index! + 1) \($0)" }, cover: detail.video.cover,
            duration: page.duration, elapsed: page.time,
            rate: page.playing ? page.playbackRate : 0, playing: page.playing, live: false,
            hasPreviousPage: index.map { $0 > 0 } ?? false,
            hasNextPage: index.map { $0 + 1 < pages.count } ?? false)
    }

    func refresh() {
        guard let workspace else { return }
        let item = Self.item(for: workspace)
        defer { published = item }
        let center = MPNowPlayingInfoCenter.default()
        guard let item else {
            if published != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            return
        }
        // Republish on any change, but not for elapsed time the system is already
        // extrapolating from the last sample and rate (samples are a second apart).
        if let last = published {
            var predicted = last
            if last.playing { predicted.elapsed += last.rate }
            var comparable = item
            comparable.elapsed = predicted.elapsed
            if comparable == predicted, abs(predicted.elapsed - item.elapsed) < 1.5 { return }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyPlaybackRate: item.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: item.live,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if !item.live, item.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = item.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.elapsed
        }
        if let artwork, artwork.url == item.cover {
            info[MPMediaItemPropertyArtwork] = artwork.value
        }
        center.nowPlayingInfo = info
        center.playbackState = item.playing ? .playing : .paused
        updateCommands(for: item)
        loadArtwork(for: item.cover)
    }

    private func loadArtwork(for url: URL?) {
        guard let url, artwork?.url != url else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await ThumbnailStore.image(url: url, pixels: 600),
                !Task.isCancelled, let self
            else { return }
            let picture = NSImage(
                cgImage: image, size: NSSize(width: image.width, height: image.height))
            artwork = (
                url,
                MPMediaItemArtwork(boundsSize: picture.size) { _ in picture }
            )
            published = nil
            refresh()
        }
    }

    private func updateCommands(for item: Item) {
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = !item.live
        commands.skipForwardCommand.isEnabled = !item.live
        commands.skipBackwardCommand.isEnabled = !item.live
        commands.previousTrackCommand.isEnabled = item.hasPreviousPage
        commands.nextTrackCommand.isEnabled = item.hasNextPage
    }

    private func registerCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        func handle(
            _ command: MPRemoteCommand,
            _ action: @escaping @MainActor (AppModel, Double?) -> Bool
        ) {
            let target = command.addTarget { [weak self] event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                // Commands may arrive on any thread. Act on the main actor without waiting
                // for it, so a busy main thread never stalls the system's command delivery.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let page = self.selectedPage(), action(page, position)
                        else { return }
                        self.published = nil
                        self.refresh()
                    }
                }
                return .success
            }
            targets.append((command, target))
        }
        handle(commands.playCommand) { page, _ in
            if !page.playing { page.togglePlayback() }
            return true
        }
        handle(commands.pauseCommand) { page, _ in
            if page.playing { page.togglePlayback() }
            return true
        }
        handle(commands.togglePlayPauseCommand) { page, _ in
            page.togglePlayback()
            return true
        }
        handle(commands.skipForwardCommand) { page, _ in
            guard page.liveSession == nil else { return false }
            page.seek(page.time + 10)
            return true
        }
        handle(commands.skipBackwardCommand) { page, _ in
            guard page.liveSession == nil else { return false }
            page.seek(max(0, page.time - 10))
            return true
        }
        handle(commands.changePlaybackPositionCommand) { page, position in
            guard page.liveSession == nil, let position else { return false }
            page.seek(position)
            return true
        }
        handle(commands.nextTrackCommand) { page, _ in Self.step(page, by: 1) }
        handle(commands.previousTrackCommand) { page, _ in Self.step(page, by: -1) }
    }

    private func selectedPage() -> AppModel? {
        guard let workspace, let id = workspace.selected else { return nil }
        return workspace.playbackInstances[id]
    }

    /// Next and previous move between 分P, like `[` and `]`.
    private static func step(_ page: AppModel, by offset: Int) -> Bool {
        guard let pages = page.detail?.pages,
            let index = pages.firstIndex(where: { $0.cid == page.pageID }),
            pages.indices.contains(index + offset)
        else { return false }
        page.selectPage(pages[index + offset].cid)
        return true
    }
}
