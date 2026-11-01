import Foundation

public struct SearchOptions: Equatable, Sendable {
    public var duration: Int
    public var days: Int
    public init(duration: Int = 0, days: Int = 0) {
        self.duration = (0...4).contains(duration) ? duration : 0
        self.days = [0, 1, 7, 30, 180].contains(days) ? days : 0
    }
    public func parameters(now: Date = Date()) -> [String: String] {
        var result = ["duration": String(duration)]
        if days > 0 {
            result["pubtime_begin_s"] = String(
                Int(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970))
            result["pubtime_end_s"] = String(Int(now.timeIntervalSince1970))
        }
        return result
    }
}

public struct SearchPerson: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let avatar: URL?
    public let biography: String
    public let followers: Int
}

extension BilibiliAPI {
    public func searchPeople(_ keyword: String, page: Int) async throws -> (
        people: [SearchPerson], hasMore: Bool
    ) {
        let data = try await request(
            "/x/web-interface/wbi/search/type",
            params: ["search_type": "bili_user", "keyword": keyword, "page": String(page)],
            signed: true)
        let people = (data["result"] as? [[String: Any]] ?? []).compactMap { row -> SearchPerson? in
            guard let id = (row["mid"] as? NSNumber)?.int64Value, id > 0 else { return nil }
            return SearchPerson(
                id: id, name: row["uname"] as? String ?? "用户",
                avatar: secureURL(row["upic"] as? String ?? ""),
                biography: row["usign"] as? String ?? "", followers: row["fans"] as? Int ?? 0)
        }
        return (people, page < (data["numPages"] as? Int ?? page))
    }
    public func searchSuggestions(_ term: String) async throws -> [String] {
        let data = try await request(
            "/x/web-interface/suggest",
            params: [
                "term": term, "main_ver": "v1", "highlight": "", "func": "suggest",
                "suggest_type": "accurate", "sub_type": "tag", "tag_num": "8", "pic_num": "0",
            ])
        let result = data["result"] as? [String: Any] ?? data
        var seen = Set<String>()
        return (result["tag"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8).map { $0 }
    }
}
