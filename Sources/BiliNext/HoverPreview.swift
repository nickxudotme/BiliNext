import AVFoundation
import BiliNextCore
import Combine

/// One muted, low-resolution preview for the entire window. It never creates a video tab.
@MainActor
final class HoverPreview: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var activeID: String?
    @Published private(set) var ready = false
    private var task: Task<Void, Never>?
    private var loader: MediaResourceLoader?
    private var status: NSKeyValueObservation?
    private var generation = UUID()
    private let resolve: (Video) async throws -> URL

    init(api: BilibiliAPI, resolve: ((Video) async throws -> URL)? = nil) {
        self.resolve =
            resolve ?? { video in
                let cid: Int64
                if let saved = video.historyCID {
                    cid = saved
                } else {
                    cid = try await api.detail(video.bvid).pages.first?.cid ?? 0
                }
                guard cid > 0 else { throw APIError(code: -1, message: "无可预览内容") }
                return try await api.playback(
                    bvid: video.bvid, cid: cid, quality: 16,
                    episodeID: video.episodeID, preferDASH: false
                ).url
            }
        player.isMuted = true
        player.volume = 0
    }

    func request(_ video: Video) {
        guard activeID != video.id else { return }
        stop()
        activeID = video.id
        let token = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                let url = try await resolve(video)
                try Task.checkCancellation()
                guard token == generation else { return }
                let loader = MediaResourceLoader(url: url)
                self.loader = loader
                let item = AVPlayerItem(asset: loader.asset)
                item.preferredForwardBufferDuration = 2
                status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        if item.status == .readyToPlay {
                            self.ready = true
                        } else if item.status == .failed {
                            self.stop()
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                player.play()
            } catch {
                guard let self, token == self.generation else { return }
                stop()
            }
        }
    }

    func stop(ifMatching id: String? = nil) {
        if let id, id != activeID { return }
        guard
            task != nil || loader != nil || status != nil || ready || activeID != nil
                || player.currentItem != nil
        else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        status = nil
        loader?.invalidate()
        loader = nil
        if ready { ready = false }
        if activeID != nil { activeID = nil }
    }
}
