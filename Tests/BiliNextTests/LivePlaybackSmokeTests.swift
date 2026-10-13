import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

// Explicit opt-in: read-only APIs, development session, muted media, no heartbeats or account writes.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_LIVE_TEST"] == "1"))
func liveFollowedPlaybackSmoke() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    _ = try await api.profile()
    let firstPage = try await api.request(
        "/xlive/web-ucenter/user/following",
        params: ["page": "1", "page_size": "100", "sort_type": "live"], live: true)
    let rows = firstPage["list"] as? [[String: Any]] ?? []
    print(
        "Following response schema: data-keys=\(firstPage.keys.sorted()), row-keys=\(rows.first?.keys.sorted() ?? []), rows=\(rows.count)"
    )
    let follows = try await api.followedLiveRooms()
    #expect(follows.allSatisfy { $0.isLive })
    let room = try await api.liveRoom(follows.first?.id ?? 6)
    #expect(room.isLive)
    let stream = try await api.livePlayback(room.id)
    let player = try MPVPlayer(videoOutput: "null")
    player.muted = true
    defer { player.stop() }
    func waitForPlayback() async throws {
        for _ in 0..<160 {
            if (player.loaded && player.time > 1) || player.failure != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(player.failure == nil)
        #expect(player.loaded && player.time > 1)
        #expect(player.number("video-params/w") > 0 && player.number("video-params/h") > 0)
        #expect(player.number("audio-params/channel-count") > 0)
    }
    try player.loadLive(stream.url, autoplay: true)
    try await waitForPlayback()
    player.pause()
    #expect(player.flag("pause"))
    try player.loadLive(stream.url, autoplay: true)
    try await waitForPlayback()
    print(
        "Live smoke: followed-online=\(follows.count), canonical-room=\(room.id), quality=\(stream.currentQuality), video=\(Int(player.number("video-params/w")))x\(Int(player.number("video-params/h"))), audio-channels=\(Int(player.number("audio-params/channel-count")))"
    )
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_LIVE_DANMAKU_TEST"] == "1"))
func liveDanmakuSocketSmoke() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    _ = try await api.profile()
    let room = try await api.liveRoom(6)
    let serverInfo = try await api.request(
        "/xlive/web-room/v1/index/getDanmuInfo", params: ["id": "\(room.id)", "type": "0"],
        signed: true, live: true)
    let hosts = serverInfo["host_list"] as? [[String: Any]] ?? []
    print(
        "Danmaku hosts: \(hosts.map { ($0["host"] as? String ?? "") + ":" + String(($0["wss_port"] as? NSNumber)?.intValue ?? 0) })"
    )
    let configuration = try await api.liveDanmakuConfiguration(room.id)
    let history = try await api.liveChatHistory(room.id)
    let socket = await api.makeLiveDanmakuSocket(configuration)
    socket.resume()
    defer { socket.cancel(with: .normalClosure, reason: nil) }
    let deadline = Task {
        try await Task.sleep(for: .seconds(35))
        socket.cancel(with: .goingAway, reason: nil)
    }
    defer { deadline.cancel() }
    try await socket.send(.data(LiveDanmakuPacket.auth(configuration)))
    try await socket.send(.data(LiveDanmakuPacket.heartbeat()))
    var authenticated = false
    var messageCount = 0
    for _ in 0..<100 {
        let received = try await socket.receive()
        let data: Data
        switch received {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: continue
        }
        let messages = try LiveDanmakuPacket.decode(data)
        if data.count >= 16, Array(data[8..<12]) == [0, 0, 0, 8] { authenticated = true }
        messageCount += messages.count
        if authenticated && messageCount > 0 { break }
    }
    #expect(authenticated)
    #expect(messageCount > 0)
    print(
        "Live danmaku smoke: authenticated=\(authenticated), messages=\(messageCount), history=\(history.count)"
    )
}
