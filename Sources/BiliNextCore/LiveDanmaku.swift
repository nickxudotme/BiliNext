import CryptoKit
import Foundation
import zlib

public struct LiveChatMessage: Identifiable, Sendable, Hashable {
    public let id: String
    public let message: String
    public let user: String
    public let userID: Int64
    public let time: Date
    public let color: UInt32

    public init(message: String, user: String, userID: Int64, time: Date, color: UInt32 = 0xFFFFFF)
    {
        self.message = message
        self.user = user
        self.userID = userID
        self.time = time
        self.color = color
        let identity = "\(userID)|\(time.timeIntervalSince1970)|\(message)|\(color)"
        id = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct LiveDanmakuConfiguration: Sendable {
    public let endpoint: URL
    public let endpoints: [URL]
    public let token: String
    public let userID: Int64
    public let roomID: Int64
    public let buvid: String

    public init(
        endpoint: URL, token: String, userID: Int64, roomID: Int64, buvid: String = "",
        endpoints: [URL] = []
    ) {
        self.endpoint = endpoint
        self.endpoints = endpoints.isEmpty ? [endpoint] : endpoints
        self.token = token
        self.userID = userID
        self.roomID = roomID
        self.buvid = buvid
    }
}

extension BilibiliAPI {
    public func liveDanmakuConfiguration(_ roomID: Int64) async throws -> LiveDanmakuConfiguration {
        let data = try await request(
            "/xlive/web-room/v1/index/getDanmuInfo", params: ["id": "\(roomID)", "type": "0"],
            signed: true, live: true)
        guard let token = data["token"] as? String, !token.isEmpty,
            let hosts = data["host_list"] as? [[String: Any]]
        else {
            throw APIError(code: -1, message: "直播弹幕连接信息不完整")
        }
        let identity = liveDanmakuIdentity()
        var seenEndpoints = Set<URL>()
        let endpoints = hosts.compactMap { host -> URL? in
            guard let name = host["host"] as? String,
                name == "bilibili.com" || name.hasSuffix(".bilibili.com"),
                !name.contains("/"), !name.contains(":")
            else { return nil }
            let port = Int(LiveParser.number(host["wss_port"]))
            guard (1...65535).contains(port) else { return nil }
            return URL(string: "wss://\(name):\(port)/sub")
        }.filter { seenEndpoints.insert($0).inserted }.sorted {
            ($0.port == 443 ? 0 : 1) < ($1.port == 443 ? 0 : 1)
        }
        if let endpoint = endpoints.first {
            return LiveDanmakuConfiguration(
                endpoint: endpoint, token: token, userID: identity.userID,
                roomID: roomID, buvid: identity.buvid, endpoints: endpoints)
        }
        throw APIError(code: -1, message: "没有可用的直播弹幕服务器")
    }

    public func liveChatHistory(_ roomID: Int64) async throws -> [LiveChatMessage] {
        let data = try await request(
            "/xlive/web-room/v1/dM/gethistory", params: ["roomid": "\(roomID)"], live: true)
        return LiveDanmakuPacket.history(data)
    }
}

public enum LiveDanmakuPacket {
    private static let maximumFrame = 8 * 1024 * 1024
    private static let maximumInflated = 2 * 1024 * 1024

    public static func auth(_ configuration: LiveDanmakuConfiguration) throws -> Data {
        var body: [String: Any] = [
            "uid": configuration.userID, "roomid": configuration.roomID, "protover": 1,
            "platform": "web", "type": 2, "key": configuration.token,
        ]
        if !configuration.buvid.isEmpty { body["buvid"] = configuration.buvid }
        return packet(operation: 7, body: try JSONSerialization.data(withJSONObject: body))
    }
    public static func heartbeat() -> Data {
        packet(operation: 2, body: Data("[object Object]".utf8))
    }

    static func packet(operation: UInt32, body: Data, version: UInt16 = 1) -> Data {
        var data = Data()
        func append(_ number: UInt32, bytes: Int) {
            for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: number >> shift))
            }
        }
        append(UInt32(body.count + 16), bytes: 4)
        append(16, bytes: 2)
        append(UInt32(version), bytes: 2)
        append(operation, bytes: 4)
        append(1, bytes: 4)
        data.append(body)
        return data
    }

    public static func decode(_ frame: Data) throws -> [LiveChatMessage] {
        var budget = maximumFrame
        return try decode(frame, depth: 0, budget: &budget)
    }
    private static func decode(_ frame: Data, depth: Int, budget: inout Int) throws
        -> [LiveChatMessage]
    {
        guard depth < 4, frame.count <= budget else { throw malformed() }
        budget -= frame.count
        let bytes = Array(frame)
        func number(_ offset: Int, _ length: Int) -> UInt32 {
            bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        var offset = 0
        var messages: [LiveChatMessage] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 16 else { throw malformed() }
            let length = Int(number(offset, 4))
            let header = Int(number(offset + 4, 2))
            let version = number(offset + 6, 2)
            let operation = number(offset + 8, 4)
            guard length >= header, header >= 16, length <= bytes.count - offset else {
                throw malformed()
            }
            let body = Data(bytes[(offset + header)..<(offset + length)])
            if operation == 5 && version == 2 {
                var output = [UInt8](repeating: 0, count: maximumInflated)
                var count = uLongf(output.count)
                let status = body.withUnsafeBytes { input in
                    uncompress(
                        &output, &count, input.bindMemory(to: Bytef.self).baseAddress,
                        uLong(body.count))
                }
                guard status == Z_OK, count <= maximumInflated else { throw malformed() }
                messages += try decode(
                    Data(output.prefix(Int(count))), depth: depth + 1, budget: &budget)
            } else if operation == 5 || operation == 8 {
                guard version <= 1,
                    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { throw malformed() }
                if operation == 8 {
                    guard object["code"] is NSNumber, LiveParser.number(object["code"]) == 0 else {
                        throw APIError(
                            code: Int(LiveParser.number(object["code"])), message: "直播弹幕认证失败")
                    }
                } else if let message = message(object) {
                    messages.append(message)
                }
            }
            offset += length
        }
        return messages
    }
    static func message(_ object: [String: Any]) -> LiveChatMessage? {
        guard let command = object["cmd"] as? String,
            command.split(separator: ":").first == "DANMU_MSG",
            let info = object["info"] as? [Any], info.count > 2,
            let text = info[1] as? String, !text.isEmpty,
            let user = info[2] as? [Any], user.count >= 2,
            let name = user[1] as? String
        else { return nil }
        let metadata = info[0] as? [Any] ?? []
        let timestamp = metadata.count > 4 ? LiveParser.number(metadata[4]) : 0
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1000 : Double(timestamp)
        let color =
            metadata.count > 3
            ? UInt32(truncatingIfNeeded: LiveParser.number(metadata[3])) : 0xFFFFFF
        return LiveChatMessage(
            message: text, user: name, userID: LiveParser.number(user[0]),
            time: Date(timeIntervalSince1970: seconds), color: color)
    }
    static func history(_ data: [String: Any]) -> [LiveChatMessage] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (data["room"] as? [[String: Any]] ?? []).compactMap { item in
            guard let text = item["text"] as? String, !text.isEmpty,
                let name = item["nickname"] as? String,
                let timeline = item["timeline"] as? String,
                let time = formatter.date(from: timeline)
            else { return nil }
            return LiveChatMessage(
                message: text, user: name, userID: LiveParser.number(item["uid"]), time: time)
        }
    }
    private static func malformed() -> APIError { APIError(code: -1, message: "直播弹幕数据格式不正确") }
}
