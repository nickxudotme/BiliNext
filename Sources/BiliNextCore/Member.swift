import Foundation

/// The header of an uploader's space page, from the public user card.
public struct MemberCard: Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var avatar: URL?
    public var banner: URL?
    public var signature: String
    public var level: Int
    /// 大会员 label such as 年度大会员, or empty.
    public var vipLabel: String
    /// Official verification text; `officialKind` is 0 for people and 1 for organisations.
    public var official: String
    public var officialKind: Int
    public var followers: Int
    public var followings: Int
    public var likes: Int
    public var videos: Int
    /// Whether the signed-in account follows this uploader; false when signed out.
    public var following: Bool

    public init(
        id: Int64, name: String, avatar: URL? = nil, banner: URL? = nil, signature: String = "",
        level: Int = 0, vipLabel: String = "", official: String = "", officialKind: Int = -1,
        followers: Int = 0, followings: Int = 0, likes: Int = 0, videos: Int = 0,
        following: Bool = false
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.banner = banner
        self.signature = signature
        self.level = level
        self.vipLabel = vipLabel
        self.official = official
        self.officialKind = officialKind
        self.followers = followers
        self.followings = followings
        self.likes = likes
        self.videos = videos
        self.following = following
    }
}

/// A 合集 (season) or 系列 (series) on an uploader's space page.
public struct MemberCollection: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case season, series }
    public var id: String { "\(kind.rawValue):\(collectionID)" }
    public let kind: Kind
    public let collectionID: Int64
    public let title: String
    public let cover: URL?
    public let count: Int
    public let updated: Date?
}

/// The uploader's live room, when they have one.
public struct MemberLiveRoom: Sendable, Equatable {
    public let roomID: Int64
    public let live: Bool
    public let title: String
}

public struct FavoriteSelection: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let selected: Bool
}
extension BilibiliAPI {
    /// The space header. Needs the public browser identifier but no signing.
    public func memberCard(mid: Int64) async throws -> MemberCard {
        try await ensureBrowserIdentifier()
        let data = try await request(
            "/x/web-interface/card", params: ["mid": String(mid), "photo": "true"])
        return parseMemberCard(data, mid: mid)
    }

    func parseMemberCard(_ data: [String: Any], mid: Int64) -> MemberCard {
        func int(_ value: Any?) -> Int {
            (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } ?? 0
        }
        let card = data["card"] as? [String: Any] ?? [:]
        let space = data["space"] as? [String: Any] ?? [:]
        let official = card["Official"] as? [String: Any] ?? [:]
        let verify = card["official_verify"] as? [String: Any] ?? [:]
        let vip = card["vip"] as? [String: Any] ?? [:]
        let label = vip["label"] as? [String: Any] ?? [:]
        let vipActive = int(vip["vipStatus"] ?? vip["status"]) == 1
        let title =
            (official["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? verify["desc"] as? String ?? ""
        let kind = official["type"] ?? verify["type"]
        return MemberCard(
            id: mid, name: card["name"] as? String ?? "UP 主",
            avatar: secureURL(card["face"] as? String ?? ""),
            banner: secureURL(space["l_img"] as? String ?? space["s_img"] as? String ?? ""),
            signature: card["sign"] as? String ?? "",
            level: int((card["level_info"] as? [String: Any])?["current_level"]),
            vipLabel: vipActive ? label["text"] as? String ?? "" : "",
            official: title, officialKind: title.isEmpty ? -1 : int(kind),
            followers: int(data["follower"] ?? card["fans"]),
            followings: int(card["attention"] ?? card["friend"]),
            likes: int(data["like_num"]), videos: int(data["archive_count"]),
            following: data["following"] as? Bool ?? false)
    }

    /// The uploader's pinned video, or nil when nothing is pinned.
    public func memberTopVideo(mid: Int64) async throws -> Video? {
        do {
            let data = try await request("/x/space/top/arc", params: ["vmid": String(mid)])
            return video(data)
        } catch let error as APIError where error.code == 53016 {
            return nil
        }
    }

    /// Newest uploads first. Unlike `memberVideos`, this public list needs no signing, so it
    /// keeps working when the signed search is risk-controlled.
    public func memberUploads(mid: Int64, page: Int = 1) async throws -> Feed {
        let data = try await request(
            "/x/space/arc/list", params: ["mid": String(mid), "pn": String(page), "ps": "30"])
        let items = (data["archives"] as? [[String: Any]] ?? []).compactMap(video)
        let info = data["page"] as? [String: Any] ?? [:]
        let count = (info["count"] as? NSNumber)?.intValue ?? 0
        return Feed(
            videos: items, next: !items.isEmpty && page * 30 < count ? String(page + 1) : nil)
    }

    /// 合集 first, then 系列, as on the space page.
    public func memberCollections(mid: Int64, page: Int = 1) async throws -> (
        collections: [MemberCollection], hasMore: Bool
    ) {
        try await ensureBrowserIdentifier()
        let data = try await request(
            "/x/polymer/web-space/seasons_series_list",
            params: ["mid": String(mid), "page_num": String(page), "page_size": "20"])
        return Self.parseCollections(data, page: page)
    }

    static func parseCollections(_ data: [String: Any], page: Int) -> (
        collections: [MemberCollection], hasMore: Bool
    ) {
        let lists = data["items_lists"] as? [String: Any] ?? [:]
        func parse(_ key: String, kind: MemberCollection.Kind, id: String) -> [MemberCollection] {
            (lists[key] as? [[String: Any]] ?? []).compactMap { item in
                let meta = item["meta"] as? [String: Any] ?? [:]
                guard let identifier = (meta[id] as? NSNumber)?.int64Value else { return nil }
                let cover =
                    (meta["cover"] as? String)
                    ?? ((item["archives"] as? [[String: Any]])?.first?["pic"] as? String) ?? ""
                return MemberCollection(
                    kind: kind, collectionID: identifier,
                    // A season's `name` repeats 「合集·」; its `title` is the bare name.
                    title: meta["title"] as? String ?? meta["name"] as? String ?? "合集",
                    cover: URL(string: cover.replacingOccurrences(of: "http://", with: "https://")),
                    count: (meta["total"] as? NSNumber)?.intValue ?? 0,
                    updated: DisplayFormat.date(
                        fromUnix: meta["ptime"] ?? meta["last_update_ts"] ?? meta["mtime"]))
            }
        }
        let collections =
            parse("seasons_list", kind: .season, id: "season_id")
            + parse("series_list", kind: .series, id: "series_id")
        let info = lists["page"] as? [String: Any] ?? [:]
        let total = (info["total"] as? NSNumber)?.intValue ?? 0
        let size = (info["page_size"] as? NSNumber)?.intValue ?? 20
        return (collections, page * size < total)
    }

    /// One 合集 or 系列 in its own order.
    public func collectionVideos(
        mid: Int64, collection: MemberCollection, page: Int = 1
    ) async throws -> Feed {
        try await ensureBrowserIdentifier()
        let data: [String: Any]
        switch collection.kind {
        case .season:
            data = try await request(
                "/x/polymer/web-space/seasons_archives_list",
                params: [
                    "mid": String(mid), "season_id": String(collection.collectionID),
                    "page_num": String(page), "page_size": "30", "sort_reverse": "false",
                ])
        case .series:
            data = try await request(
                "/x/series/archives",
                params: [
                    "mid": String(mid), "series_id": String(collection.collectionID),
                    "pn": String(page), "ps": "30", "sort": "desc",
                ])
        }
        let items = (data["archives"] as? [[String: Any]] ?? []).compactMap(video)
        let info = data["page"] as? [String: Any] ?? [:]
        let total = (info["total"] as? NSNumber)?.intValue ?? 0
        return Feed(
            videos: items, next: !items.isEmpty && page * 30 < total ? String(page + 1) : nil)
    }

    /// The uploader's live room, or nil when they have never opened one.
    public func memberLiveRoom(mid: Int64) async throws -> MemberLiveRoom? {
        let data = try await request(
            "/room/v1/Room/getRoomInfoOld", params: ["mid": String(mid)], live: true)
        guard let room = (data["roomid"] as? NSNumber)?.int64Value, room > 0 else { return nil }
        return MemberLiveRoom(
            roomID: room, live: (data["liveStatus"] as? NSNumber)?.intValue == 1,
            title: data["title"] as? String ?? "")
    }

    /// Follows or unfollows. Only ever called from the user's own click.
    public func setFollowing(mid: Int64, _ follow: Bool) async throws {
        _ = try await request(
            "/x/relation/modify",
            form: ["fid": String(mid), "act": follow ? "1" : "2", "re_src": "11"])
    }

    public func memberVideos(
        mid: Int64, page: Int = 1, keyword: String = "", order: String = "pubdate"
    ) async throws -> Feed {
        let data = try await request(
            "/x/space/wbi/arc/search",
            params: [
                "mid": String(mid), "pn": String(page), "ps": "30", "keyword": keyword,
                "order": order, "platform": "web",
            ], signed: true)
        let list = data["list"] as? [String: Any] ?? [:]
        let items = (list["vlist"] as? [[String: Any]] ?? []).compactMap(video)
        let info = data["page"] as? [String: Any] ?? [:]
        let count = (info["count"] as? NSNumber)?.intValue ?? 0
        return Feed(
            videos: items, next: !items.isEmpty && page * 30 < count ? String(page + 1) : nil)
    }
    public func favoriteSelection(mid: Int64, aid: Int64) async throws -> [FavoriteSelection] {
        let data = try await request(
            "/x/v3/fav/folder/created/list-all",
            params: ["up_mid": String(mid), "rid": String(aid), "type": "2"])
        return (data["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.int64Value else { return nil }
            return FavoriteSelection(
                id: id, title: item["title"] as? String ?? "收藏夹",
                selected: (item["fav_state"] as? NSNumber)?.intValue == 1)
        }
    }
    public func saveFavorites(aid: Int64, add: Set<Int64>, remove: Set<Int64>) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        _ = try await request(
            "/x/v3/fav/resource/batch-deal",
            form: [
                "resources": "\(aid):2",
                "add_media_ids": add.sorted().map(String.init).joined(separator: ","),
                "del_media_ids": remove.sorted().map(String.init).joined(separator: ","),
            ])
    }
}
