import BiliNextCore
import Combine
import Foundation

@MainActor
final class LiveChatModel: ObservableObject {
    @Published private(set) var messages: [LiveChatMessage] = []
    @Published private(set) var liveMessages: [LiveChatMessage] = []
    @Published private(set) var status = "未连接"
    @Published private(set) var connected = false
    private let api: BilibiliAPI
    private var roomID: Int64?
    private var task: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var pending: [LiveChatMessage] = []
    private var pendingLive: [LiveChatMessage] = []
    private var seen = Set<String>()

    init(api: BilibiliAPI) { self.api = api }

    func start(roomID: Int64) {
        guard self.roomID != roomID || task == nil else { return }
        stop()
        if self.roomID != roomID {
            messages = []
            seen = []
        }
        self.roomID = roomID
        let token = generation
        status = "正在连接"
        task = Task {
            if let history = try? await api.liveChatHistory(roomID), !Task.isCancelled,
                generation == token
            {
                enqueue(history)
            }
            var retry = 0
            while !Task.isCancelled && generation == token {
                do {
                    let config = try await api.liveDanmakuConfiguration(roomID)
                    guard !Task.isCancelled, generation == token else { return }
                    let endpoint = config.endpoints[retry % config.endpoints.count]
                    let socket = await api.makeLiveDanmakuSocket(config, endpoint: endpoint)
                    self.socket = socket
                    socket.resume()
                    try await socket.send(.data(try LiveDanmakuPacket.auth(config)))
                    try await socket.send(.data(LiveDanmakuPacket.heartbeat()))
                    heartbeat = Task {
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for: .seconds(30))
                                try Task.checkCancellation()
                                try await socket.send(.data(LiveDanmakuPacket.heartbeat()))
                            } catch {
                                if !Task.isCancelled {
                                    socket.cancel(with: .goingAway, reason: nil)
                                }
                                return
                            }
                        }
                    }
                    while !Task.isCancelled && generation == token {
                        let frame = try await socket.receive()
                        let bytes: Data
                        switch frame {
                        case .data(let data): bytes = data
                        case .string(let text): bytes = Data(text.utf8)
                        @unknown default: continue
                        }
                        let received = try await Task.detached(priority: .utility) {
                            try LiveDanmakuPacket.decode(bytes)
                        }.value
                        guard !Task.isCancelled, generation == token else { return }
                        connected = true
                        status = "实时连接"
                        retry = 0
                        enqueue(received, realtime: true)
                    }
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    connected = false
                    status = "连接中断，正在重连"
                }
                heartbeat?.cancel()
                heartbeat = nil
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                retry += 1
                do { try await Task.sleep(for: .seconds(min(30, retry * 2))) } catch { return }
            }
        }
    }

    func reconnect() {
        guard let roomID else { return }
        stop()
        start(roomID: roomID)
    }

    private func enqueue(_ values: [LiveChatMessage], realtime: Bool = false) {
        for value in values where seen.insert(value.id).inserted {
            pending.append(value)
            if realtime { pendingLive.append(value) }
        }
        pendingLive = Array(pendingLive.suffix(200))
        pending = Array(pending.suffix(500))
        guard !pending.isEmpty, flushTask == nil else { return }
        let token = generation
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, generation == token else { return }
            messages = Array((messages + pending).suffix(500))
            liveMessages = Array((liveMessages + pendingLive).suffix(200))
            pendingLive = []
            pending = []
            seen = Set(messages.map(\.id))
            flushTask = nil
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        heartbeat?.cancel()
        heartbeat = nil
        flushTask?.cancel()
        flushTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pending = []
        pendingLive = []
        liveMessages = []
        connected = false
        seen = Set(messages.map(\.id))
        status = "已暂停接收"
    }
}
