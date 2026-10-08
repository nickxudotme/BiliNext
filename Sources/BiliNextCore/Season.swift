import Foundation

public struct Season: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let cover: URL?
    public let update: String
    public let badge: String
}
public struct SeasonDetail: Sendable {
    public let title: String
    public let description: String
    public let episodes: [Video]
}
extension BilibiliAPI {
    public func seasons(type: Int = 1, page: Int = 1, order: Int = 3) async throws -> [Season] {
        let data = try await request(
            "/pgc/season/index/result",
            params: [
                "season_type": String(type), "type": "1", "page": String(page), "pagesize": "20",
                "order": String(order), "sort": "0", "season_status": "-1",
            ])
        return (data["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["season_id"] as? NSNumber)?.int64Value else { return nil }
            return Season(
                id: id, title: item["title"] as? String ?? "番剧",
                cover: secureURL(item["cover"] as? String ?? ""),
                update: item["index_show"] as? String ?? "", badge: item["badge"] as? String ?? "")
        }
    }
    public func season(id: Int64) async throws -> SeasonDetail {
        let data = try await request("/pgc/view/web/season", params: ["season_id": String(id)])
        let title = data["title"] as? String ?? "番剧"
        let episodes = (data["episodes"] as? [[String: Any]] ?? []).compactMap { item -> Video? in
            guard let bvid = item["bvid"] as? String, !bvid.isEmpty,
                let cid = (item["cid"] as? NSNumber)?.int64Value,
                let ep = (item["id"] as? NSNumber)?.int64Value
            else { return nil }
            let label = item["title"] as? String ?? ""
            let long = item["long_title"] as? String ?? ""
            return Video(
                bvid: bvid, title: title + " · " + label + " " + long, author: title,
                cover: secureURL(item["cover"] as? String ?? ""),
                aid: (item["aid"] as? NSNumber)?.int64Value,
                duration: (item["duration"] as? NSNumber).map { $0.doubleValue / 1000 },
                historyCID: cid, episodeID: ep)
        }
        return SeasonDetail(
            title: title, description: data["evaluate"] as? String ?? "", episodes: episodes)
    }
}
