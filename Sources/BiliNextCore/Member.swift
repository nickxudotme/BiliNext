import Foundation

public struct MemberProfile: Sendable {
    public let id: Int64
    public let name: String
    public let avatar: URL?
    public let signature: String
}
public struct FavoriteSelection: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let selected: Bool
}
extension BilibiliAPI {
    public func member(mid: Int64) async throws -> MemberProfile {
        let data = try await request("/x/space/wbi/acc/info", params: ["mid": String(mid)], signed: true)
        return MemberProfile(id: mid, name: data["name"] as? String ?? "UP 主", avatar: secureURL(data["face"] as? String ?? ""), signature: data["sign"] as? String ?? "")
    }
    public func memberVideos(mid: Int64, page: Int = 1, keyword: String = "", order: String = "pubdate") async throws -> Feed {
        let data = try await request("/x/space/wbi/arc/search", params: ["mid": String(mid), "pn": String(page), "ps": "30", "keyword": keyword, "order": order, "platform": "web"], signed: true)
        let list = data["list"] as? [String: Any] ?? [:]
        let items = (list["vlist"] as? [[String: Any]] ?? []).compactMap(video)
        let info = data["page"] as? [String: Any] ?? [:]
        let count = (info["count"] as? NSNumber)?.intValue ?? 0
        return Feed(videos: items, next: !items.isEmpty && page * 30 < count ? String(page + 1) : nil)
    }
    public func favoriteSelection(mid: Int64, aid: Int64) async throws -> [FavoriteSelection] {
        let data = try await request("/x/v3/fav/folder/created/list-all", params: ["up_mid": String(mid), "rid": String(aid), "type": "2"])
        return (data["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.int64Value else { return nil }
            return FavoriteSelection(id: id, title: item["title"] as? String ?? "收藏夹", selected: (item["fav_state"] as? NSNumber)?.intValue == 1)
        }
    }
    public func saveFavorites(aid: Int64, add: Set<Int64>, remove: Set<Int64>) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        _ = try await request("/x/v3/fav/resource/batch-deal", form: ["resources": "\(aid):2", "add_media_ids": add.sorted().map(String.init).joined(separator: ","), "del_media_ids": remove.sorted().map(String.init).joined(separator: ",")])
    }
}
