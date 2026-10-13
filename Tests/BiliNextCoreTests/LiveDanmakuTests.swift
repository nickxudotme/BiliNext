import Foundation
import Testing
import zlib

@testable import BiliNextCore

private func chatBody(_ text: String = "直播弹幕") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "cmd": "DANMU_MSG:4:0:2",
        "info": [[0, 1, 25, 16_711_680, 1_791_911_400_000], text, [42, "观众", 0]],
    ])
}

@Test func liveDanmakuAuthenticationAndHeartbeatUseBigEndianFraming() throws {
    let configuration = LiveDanmakuConfiguration(
        endpoint: URL(string: "wss://example.bilibili.com/sub")!, token: "fixture", userID: 42,
        roomID: 6, buvid: "fixture-browser")
    let auth = try LiveDanmakuPacket.auth(configuration)
    #expect(Array(auth[4..<16]) == [0, 16, 0, 1, 0, 0, 0, 7, 0, 0, 0, 1])
    let body = try #require(
        JSONSerialization.jsonObject(with: auth.dropFirst(16)) as? [String: Any])
    #expect(body["roomid"] as? Int == 6 && body["protover"] as? Int == 1)
    #expect(body["key"] as? String == "fixture" && body["buvid"] as? String == "fixture-browser")
    let heartbeat = LiveDanmakuPacket.heartbeat()
    #expect(heartbeat[11] == 2 && heartbeat.count == 31)
}

@Test func liveDanmakuDecodesBatchedMessagesIgnoresOtherEventsAndRejectsAuthentication() throws {
    let message = LiveDanmakuPacket.packet(operation: 5, body: try chatBody())
    let heartbeat = LiveDanmakuPacket.packet(operation: 3, body: Data([0, 0, 0, 10]))
    let ignored = LiveDanmakuPacket.packet(operation: 5, body: Data(#"{"cmd":"SEND_GIFT"}"#.utf8))
    let decoded = try LiveDanmakuPacket.decode(heartbeat + message + ignored + message)
    #expect(decoded.count == 2)
    #expect(decoded.first?.message == "直播弹幕" && decoded.first?.user == "观众")
    #expect(decoded.first?.userID == 42 && decoded.first?.color == 0xFF0000)
    #expect(decoded.first?.time.timeIntervalSince1970 == 1_791_911_400)
    #expect(decoded[0].id == decoded[1].id)
    #expect(
        try LiveDanmakuPacket.decode(
            LiveDanmakuPacket.packet(operation: 8, body: Data(#"{"code":0}"#.utf8))
        ).isEmpty)
    #expect(throws: APIError.self) {
        try LiveDanmakuPacket.decode(
            LiveDanmakuPacket.packet(operation: 8, body: Data(#"{"code":-101}"#.utf8)))
    }
}

@Test func liveDanmakuInflatesZlibAndRejectsTruncatedOversizeAndUnsupportedFrames() throws {
    let packet = LiveDanmakuPacket.packet(operation: 5, body: try chatBody())
    var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(packet.count))))
    var count = uLongf(compressed.count)
    let status = packet.withUnsafeBytes { buffer in
        compress(
            &compressed, &count, buffer.bindMemory(to: Bytef.self).baseAddress, uLong(packet.count))
    }
    #expect(status == Z_OK)
    let wrapped = LiveDanmakuPacket.packet(
        operation: 5, body: Data(compressed.prefix(Int(count))), version: 2)
    #expect(try LiveDanmakuPacket.decode(wrapped).count == 1)
    for invalid in [
        Data([0]), packet.dropLast(),
        LiveDanmakuPacket.packet(operation: 5, body: Data([1, 2, 3]), version: 2),
        LiveDanmakuPacket.packet(operation: 5, body: Data(), version: 3),
        Data(repeating: 0, count: 8 * 1024 * 1024 + 1),
    ] {
        #expect(throws: (any Error).self) { try LiveDanmakuPacket.decode(Data(invalid)) }
    }
    let oversized = Data(repeating: 0, count: 2 * 1024 * 1024 + 1)
    var bomb = [UInt8](repeating: 0, count: Int(compressBound(uLong(oversized.count))))
    var bombCount = uLongf(bomb.count)
    _ = oversized.withUnsafeBytes { buffer in
        compress(
            &bomb, &bombCount, buffer.bindMemory(to: Bytef.self).baseAddress, uLong(oversized.count)
        )
    }
    #expect(throws: APIError.self) {
        try LiveDanmakuPacket.decode(
            LiveDanmakuPacket.packet(
                operation: 5, body: Data(bomb.prefix(Int(bombCount))), version: 2))
    }
    var shortHeader = packet
    shortHeader[5] = 15
    #expect(throws: APIError.self) { try LiveDanmakuPacket.decode(shortHeader) }
}

@Test func liveDanmakuHistoryPreservesOrderingAndSkipsMalformedRows() {
    let history = LiveDanmakuPacket.history([
        "room": [
            ["text": "第一条", "nickname": "甲", "uid": 1, "timeline": "2026-10-14 01:00:00"],
            ["text": "无时间", "nickname": "乙", "uid": 2],
            ["text": "第二条", "nickname": "乙", "uid": 2, "timeline": "2026-10-14 01:00:01"],
        ]
    ])
    #expect(history.map(\.message) == ["第一条", "第二条"])
    #expect(history[1].time.timeIntervalSince(history[0].time) == 1)
}
