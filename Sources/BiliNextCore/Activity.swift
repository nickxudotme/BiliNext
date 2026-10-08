import Foundation

public struct Activity: Identifiable, Sendable {
    public let id: String
    public let author: String
    public let avatar: URL?
    public let mid: Int64?
    public let time: String
    public let text: String
    public let images: [URL]
    public let video: Video?
    public let original: String?
    public let link: URL?
}
public struct ActivityPage: Sendable {
    public let items: [Activity]
    public let next: String?
}
extension BilibiliAPI {
    public func activities(offset: String? = nil) async throws -> ActivityPage {
        var params = ["type": "all", "timezone_offset": "-480", "features": "itemOpusStyle"]
        if let offset { params["offset"] = offset }
        let data = try await request("/x/polymer/web-dynamic/v1/feed/all", params: params)
        let items = (data["items"] as? [[String: Any]] ?? []).compactMap { item -> Activity? in
            guard let id = item["id_str"] as? String else { return nil }
            let modules = item["modules"] as? [String: Any] ?? [:]
            let author = modules["module_author"] as? [String: Any] ?? [:]
            let dynamic = modules["module_dynamic"] as? [String: Any] ?? [:]
            let desc = dynamic["desc"] as? [String: Any] ?? [:]
            let major = dynamic["major"] as? [String: Any] ?? [:]
            let opus = major["opus"] as? [String: Any] ?? [:]
            let summary = opus["summary"] as? [String: Any] ?? [:]
            let draw = major["draw"] as? [String: Any] ?? [:]
            let article = major["article"] as? [String: Any] ?? [:]
            var pictures = (draw["items"] as? [[String: Any]] ?? []).compactMap {
                secureURL($0["src"] as? String ?? "")
            }
            pictures += (opus["pics"] as? [[String: Any]] ?? []).compactMap {
                secureURL($0["url"] as? String ?? "")
            }
            var archive = major["archive"] as? [String: Any] ?? [:]
            archive["owner"] = [
                "name": author["name"] ?? "", "face": author["face"] ?? "",
                "mid": author["mid"] ?? 0,
            ]
            let original = item["orig"] as? [String: Any]
            let originalModules = original?["modules"] as? [String: Any] ?? [:]
            let originalAuthor = originalModules["module_author"] as? [String: Any] ?? [:]
            let originalDynamic = originalModules["module_dynamic"] as? [String: Any] ?? [:]
            let originalDesc = originalDynamic["desc"] as? [String: Any] ?? [:]
            let originalMajor = originalDynamic["major"] as? [String: Any] ?? [:]
            let originalArchive = originalMajor["archive"] as? [String: Any] ?? [:]
            let originalOpus = originalMajor["opus"] as? [String: Any] ?? [:]
            let originalSummary = originalOpus["summary"] as? [String: Any] ?? [:]
            let originalText =
                original == nil
                ? nil
                : "@" + (originalAuthor["name"] as? String ?? "原动态") + "："
                    + (originalDesc["text"] as? String ?? originalSummary["text"] as? String
                        ?? originalArchive["title"] as? String ?? "查看转发内容")
            return Activity(
                id: id, author: author["name"] as? String ?? "用户",
                avatar: secureURL(author["face"] as? String ?? ""),
                mid: (author["mid"] as? NSNumber)?.int64Value,
                time: author["pub_time"] as? String ?? "",
                text: desc["text"] as? String ?? summary["text"] as? String ?? article["title"]
                    as? String ?? "", images: pictures, video: video(archive),
                original: originalText,
                link: secureURL(
                    article["jump_url"] as? String ?? opus["jump_url"] as? String
                        ?? "https://t.bilibili.com/\(id)"))
        }
        return ActivityPage(
            items: items, next: data["has_more"] as? Bool == true ? data["offset"] as? String : nil)
    }
}
