import Foundation

public struct Comment: Identifiable, Sendable {
    public let id: Int64
    public let parentID: Int64
    public let rootID: Int64
    public let author: String
    public let avatar: URL?
    public let text: String
    public let likes: Int
    public let replyCount: Int
    public let date: Date
    public let replies: [Comment]
    public static func parse(_ value: [String: Any]) -> Comment? {
        guard let id = (value["rpid"] as? NSNumber)?.int64Value else { return nil }
        let member = value["member"] as? [String: Any] ?? [:]
        let content = value["content"] as? [String: Any] ?? [:]
        return Comment(id: id, parentID: (value["parent"] as? NSNumber)?.int64Value ?? 0, rootID: (value["root"] as? NSNumber)?.int64Value ?? 0, author: member["uname"] as? String ?? "用户", avatar: secureURL(member["avatar"] as? String ?? ""), text: content["message"] as? String ?? "", likes: (value["like"] as? NSNumber)?.intValue ?? 0, replyCount: (value["rcount"] as? NSNumber)?.intValue ?? 0, date: Date(timeIntervalSince1970: (value["ctime"] as? NSNumber)?.doubleValue ?? 0), replies: (value["replies"] as? [[String: Any]] ?? []).compactMap(parse))
    }
}

public struct CommentBranch: Identifiable, Sendable {
    public var id: Int64 { comment.id }
    public let comment: Comment
    public let children: [CommentBranch]
    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    /// API reply pages are flat. Only attach known parents; orphaned replies stay
    /// visible until a later page brings their parent into the loaded set.
    public static func forest(_ comments: [Comment], rootID: Int64) -> [CommentBranch] {
        var seen = Set<Int64>()
        let unique = comments.filter { $0.id != rootID && seen.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        var parents: [Int64: Int64] = [:]
        for comment in unique {
            var ancestors: Set<Int64> = [comment.id]
            var candidate = comment.parentID
            var valid = true
            while let parent = byID[candidate] {
                if !ancestors.insert(candidate).inserted { valid = false; break }
                candidate = parent.parentID
            }
            if valid, byID[comment.parentID] != nil { parents[comment.id] = comment.parentID }
        }
        let children = Dictionary(grouping: unique.filter { parents[$0.id] != nil }, by: { parents[$0.id]! })
        func branch(_ comment: Comment) -> CommentBranch {
            CommentBranch(comment: comment, children: (children[comment.id] ?? []).map(branch))
        }
        return unique.filter { parents[$0.id] == nil }.map(branch)
    }
}
public struct CommentPage: Sendable {
    public let comments: [Comment]
    public let count: Int
    public let hasMore: Bool
}

extension BilibiliAPI {
    public func videoRelation(bvid: String) async throws -> (liked: Bool, coins: Int) {
        let data = try await request("/x/web-interface/archive/relation", params: ["bvid": bvid])
        return (data["like"] as? Bool ?? false, (data["coin"] as? NSNumber)?.intValue ?? 0)
    }
    public func likeVideo(bvid: String, liked: Bool) async throws {
        _ = try await request("/x/web-interface/archive/like", form: ["bvid": bvid, "like": liked ? "1" : "2"])
    }
    public func coinVideo(bvid: String, count: Int) async throws {
        guard (1...2).contains(count) else { throw APIError(code: -1, message: "投币数量无效") }
        _ = try await request("/x/web-interface/coin/add", form: ["bvid": bvid, "multiply": String(count), "select_like": "0"])
    }
    public func related(bvid: String) async throws -> [Video] {
        // This endpoint returns an array in data; requestArray retains the common HTTP checks.
        return try await requestArray("/x/web-interface/archive/related", params: ["bvid": bvid]).compactMap(video)
    }
    public func comments(aid: Int64, page: Int = 1, newest: Bool = false, root: Int64? = nil) async throws -> CommentPage {
        var params = ["oid": String(aid), "type": "1", "pn": String(page), "ps": "20", "sort": newest ? "0" : "1"]
        if let root { params["root"] = String(root) }
        let data = try await request(root == nil ? "/x/v2/reply" : "/x/v2/reply/reply", params: params)
        let info = data["page"] as? [String: Any] ?? [:]
        let count = (info["count"] as? NSNumber)?.intValue ?? 0
        var items = (data["replies"] as? [[String: Any]] ?? []).compactMap(Comment.parse)
        if page == 1, root == nil, let upper = data["upper"] as? [String: Any], let top = upper["top"] as? [String: Any], let comment = Comment.parse(top) { items.insert(comment, at: 0) }
        var seen = Set<Int64>(); items = items.filter { seen.insert($0.id).inserted }
        return CommentPage(comments: items, count: count, hasMore: !items.isEmpty && page * 20 < count)
    }
    public func ranking() async throws -> [Video] {
        let data = try await request("/x/web-interface/ranking/v2", params: ["rid": "0", "type": "all"])
        return (data["list"] as? [[String: Any]] ?? []).compactMap(video)
    }
    public func recommended(page: Int = 1) async throws -> [Video] {
        let data = try await request("/x/web-interface/wbi/index/top/feed/rcmd", params: ["fresh_type": "3", "ps": "20", "fresh_idx": String(page), "fresh_idx_1h": String(page), "feed_version": "V8", "homepage_ver": "1"], signed: true)
        return (data["item"] as? [[String: Any]] ?? []).compactMap(video)
    }
}
