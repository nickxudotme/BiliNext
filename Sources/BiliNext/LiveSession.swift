import BiliNextCore
import Combine
import Foundation

@MainActor
final class LiveSession: ObservableObject {
    let requestedRoomID: Int64
    let chat: LiveChatModel
    @Published private(set) var room: LiveRoom?
    @Published private(set) var player: MPVPlayer?
    @Published private(set) var loading = false
    @Published private(set) var buffering = false
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    @Published private(set) var qualities: [LiveQuality] = []
    @Published private(set) var quality = 10000
    @Published var volume = 1.0 { didSet { player?.volume = volume } }
    var onPlaying: ((Bool) -> Void)?
    var onRoom: ((LiveRoom) -> Void)?
    private let api: BilibiliAPI
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var active = false
    private var wantsPlayback = false
    private var resolving = false
    private var candidates: [URL] = []
    private var candidateIndex = 0

    init(api: BilibiliAPI, roomID: Int64) {
        self.api = api
        chat = LiveChatModel(api: api)
        requestedRoomID = roomID
    }

    static func roomID(_ tabID: String) -> Int64? {
        guard tabID.hasPrefix("live:"), let value = Int64(tabID.dropFirst(5)), value > 0
        else { return nil }
        return value
    }

    func setActive(_ value: Bool, autoplay: Bool) {
        active = value
        if autoplay { wantsPlayback = true }
        if value && wantsPlayback { player?.play() } else { player?.pause() }
        if value, let room, room.isLive { chat.start(roomID: room.id) }
        if !value { chat.stop() }
    }

    func suspend() {
        chat.stop()
        active = false
        wantsPlayback = false
        player?.pause()
        playing = false
        onPlaying?(false)
    }

    func togglePlayback() {
        wantsPlayback.toggle()
        if wantsPlayback && active { player?.play() } else { player?.pause() }
    }

    func selectQuality(_ value: Int) {
        guard value != quality else { return }
        quality = value
        reload()
    }

    func reload() {
        task?.cancel()
        let request = UUID()
        generation = request
        resolving = true
        candidates = []
        candidateIndex = 0
        buffering = false
        player?.stop()
        loading = true
        error = nil
        playing = false
        onPlaying?(false)
        task = Task {
            do {
                let room = try await api.liveRoom(requestedRoomID)
                guard !Task.isCancelled, generation == request else { return }
                self.room = room
                onRoom?(room)
                guard room.isLive else {
                    chat.stop()
                    resolving = false
                    loading = false
                    buffering = false
                    return
                }
                if active { chat.start(roomID: room.id) }
                let stream = try await api.livePlayback(room.id, quality: quality)
                guard !Task.isCancelled, generation == request else { return }
                qualities = stream.qualities
                quality = stream.currentQuality
                candidates = [stream.url] + stream.backupURLs
                candidateIndex = 0
                if player == nil {
                    let core = try MPVPlayer()
                    core.onUpdate = { [weak self] _, _, playing, buffering in
                        self?.update(playing: playing, buffering: buffering)
                    }
                    player = core
                }
                player?.volume = volume
                try player?.loadLive(stream.url, autoplay: active && wantsPlayback)
                resolving = false
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                self.error = error.localizedDescription
                resolving = false
                loading = false
                buffering = false
            }
        }
    }

    private func update(playing: Bool, buffering: Bool) {
        guard !resolving, room?.isLive == true else { return }
        if let failure = player?.failure {
            if candidateIndex + 1 < candidates.count {
                candidateIndex += 1
                do {
                    try player?.loadLive(
                        candidates[candidateIndex], autoplay: active && wantsPlayback)
                } catch { self.error = error.localizedDescription }
                return
            }
            error = "直播播放失败：\(failure)"
            loading = false
            self.buffering = false
        } else {
            if player?.loaded == true { loading = false }
            self.buffering = buffering
        }
        self.playing = playing
        onPlaying?(playing)
    }

    func stop() {
        chat.stop()
        task?.cancel()
        generation = UUID()
        resolving = true
        active = false
        wantsPlayback = false
        player?.stop()
        playing = false
        onPlaying?(false)
    }
}
