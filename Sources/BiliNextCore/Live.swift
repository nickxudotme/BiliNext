import Foundation

public struct LiveRoom: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var author: String
    public var cover: String
    public var avatar: String
    public var isLive: Bool
    public var areaName: String

    public init(
        id: Int64, title: String, author: String = "", cover: String = "", avatar: String = "",
        isLive: Bool = false, areaName: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.cover = cover
        self.avatar = avatar
        self.isLive = isLive
        self.areaName = areaName
    }
}

public struct LiveQuality: Identifiable, Hashable, Sendable {
    public var id: Int
    public var title: String
}

public struct LivePlayback: Sendable {
    public var roomID: Int64
    public var url: URL
    public var backupURLs: [URL]
    public var qualities: [LiveQuality]
    public var currentQuality: Int
}

extension BilibiliAPI {
    public func followedLiveRooms() async throws -> [LiveRoom] {
        var rooms: [LiveRoom] = []
        var seen = Set<Int64>()
        // The following endpoint includes offline follows; collect every page before filtering.
        for page in 1...100 {
            let data = try await request(
                "/xlive/web-ucenter/user/following",
                params: [
                    "page": "\(page)", "page_size": "100", "ignoreRecord": "1", "hit_ab": "true",
                    "sort_type": "live",
                ], live: true)
            let additions = LiveParser.followedRooms(data).filter { seen.insert($0.id).inserted }
            rooms += additions
            if !LiveParser.hasMoreFollowedRooms(data, page: page) { break }
            try Task.checkCancellation()
        }
        return rooms
    }

    public func liveRoom(_ id: Int64) async throws -> LiveRoom {
        let data = try await request(
            "/room/v1/Room/get_info", params: ["room_id": "\(id)"], live: true)
        guard var room = LiveParser.room(data) else {
            throw APIError(code: -1, message: "直播间信息不完整")
        }
        let anchor = try? await request(
            "/live_user/v1/UserInfo/get_anchor_in_room", params: ["roomid": "\(room.id)"],
            live: true)
        try Task.checkCancellation()
        let info = anchor?["info"] as? [String: Any] ?? [:]
        room.author = info["uname"] as? String ?? ""
        room.avatar = LiveParser.image(info["face"])
        return room
    }

    public func livePlayback(_ id: Int64, quality: Int = 10000) async throws -> LivePlayback {
        let data = try await request(
            "/xlive/web-room/v2/index/getRoomPlayInfo",
            params: [
                "room_id": "\(id)", "protocol": "0,1", "format": "0,1,2", "codec": "0,1",
                "qn": "\(quality)", "platform": "web", "ptype": "8",
            ], live: true)
        return try LiveParser.playback(data)
    }
}

// Parses response data rather than retaining expiring stream URLs in saved rooms.
enum LiveParser {
    static func number(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        return Int64(value as? String ?? "") ?? 0
    }
    static func image(_ value: Any?) -> String {
        let value = value as? String ?? ""
        return value.hasPrefix("//") ? "https:" + value : value
    }
    static func room(_ data: [String: Any], defaultLive: Bool = false) -> LiveRoom? {
        let id = number(data["room_id"] ?? data["roomid"])
        guard id > 0 else { return nil }
        let title = (data["title"] as? String ?? "直播间").replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        return LiveRoom(
            id: id, title: title, author: data["uname"] as? String ?? "",
            cover: image(
                data["cover"] ?? data["user_cover"] ?? data["room_cover"] ?? data["pic"]
                    ?? data["keyframe"]),
            avatar: image(data["face"] ?? data["uface"]),
            isLive: data["live_status"] == nil ? defaultLive : number(data["live_status"]) == 1,
            areaName: data["area_v2_name"] as? String ?? data["area_name_v2"] as? String ?? data[
                "area_name"] as? String ?? "")
    }
    static func hasMoreFollowedRooms(_ data: [String: Any], page: Int) -> Bool {
        let totalPages = number(data["totalPage"] ?? data["total_page"])
        if totalPages > 0 { return page < totalPages }
        let size = number(data["pageSize"] ?? data["page_size"])
        return (data["list"] as? [[String: Any]] ?? []).count >= (size > 0 ? Int(size) : 100)
    }
    static func followedRooms(_ data: [String: Any]) -> [LiveRoom] {
        (data["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let room = room(item), room.isLive else { return nil }
            return room
        }
    }
    static func dynamicRoom(major: [String: Any], author: [String: Any]) -> LiveRoom? {
        var payload = major["live"] as? [String: Any]
        if let recommendation = major["live_rcmd"] as? [String: Any],
            let content = recommendation["content"] as? String,
            let data = content.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            payload =
                decoded["live_play_info"] as? [String: Any]
                ?? (decoded["card_info"] as? [String: Any])?["live_play_info"] as? [String: Any]
        }
        guard var payload else { return nil }
        payload["uname"] = author["name"] ?? payload["uname"]
        payload["face"] = author["face"] ?? payload["face"]
        return room(payload)
    }
    static func playback(_ data: [String: Any]) throws -> LivePlayback {
        guard number(data["live_status"]) == 1 else { throw APIError(code: -1, message: "主播尚未开播") }
        if data["encrypted"] as? Bool == true && data["pwd_verified"] as? Bool != true {
            throw APIError(code: -1, message: "直播间需要密码，请在官方客户端观看")
        }
        let info = data["playurl_info"] as? [String: Any] ?? [:]
        let play = info["playurl"] as? [String: Any] ?? [:]
        var candidates: [(rank: Int, codec: [String: Any], urls: [URL])] = []
        for stream in play["stream"] as? [[String: Any]] ?? [] {
            for format in stream["format"] as? [[String: Any]] ?? [] {
                let name = format["format_name"] as? String ?? ""
                guard ["flv", "ts", "fmp4"].contains(name) else { continue }
                for codec in format["codec"] as? [[String: Any]] ?? [] {
                    guard codec["drm"] as? Bool != true, let base = codec["base_url"] as? String
                    else { continue }
                    let urls = (codec["url_info"] as? [[String: Any]] ?? []).compactMap {
                        item -> URL? in
                        guard let host = item["host"] as? String else { return nil }
                        let extra = item["extra"] as? String ?? ""
                        let separator =
                            extra.isEmpty || extra.hasPrefix("?") || extra.hasPrefix("&")
                                || base.hasSuffix("?") ? "" : (base.contains("?") ? "&" : "?")
                        guard let url = URL(string: host + base + separator + extra),
                            ["https", "http"].contains(url.scheme), url.host != nil
                        else { return nil }
                        return url
                    }
                    if !urls.isEmpty {
                        candidates.append(
                            (
                                name == "flv"
                                    ? (codec["codec_name"] as? String == "avc" ? 0 : 1) : 2, codec,
                                urls
                            ))
                    }
                }
            }
        }
        guard let candidate = candidates.sorted(by: { $0.rank < $1.rank }).first,
            let url = candidate.urls.first
        else {
            throw APIError(code: -1, message: "直播间暂时没有可播放的直播流")
        }
        let accepted = Set((candidate.codec["accept_qn"] as? [NSNumber] ?? []).map(\.intValue))
        let qualities = (play["g_qn_desc"] as? [[String: Any]] ?? []).compactMap {
            item -> LiveQuality? in
            let id = Int(number(item["qn"]))
            guard accepted.contains(id) else { return nil }
            return LiveQuality(id: id, title: item["desc"] as? String ?? "\(id)")
        }
        return LivePlayback(
            roomID: number(data["room_id"]), url: url,
            backupURLs: Array(candidate.urls.dropFirst()), qualities: qualities,
            currentQuality: Int(number(candidate.codec["current_qn"])))
    }
}
