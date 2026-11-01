import Foundation

public struct Comment: Identifiable, Sendable {
    public let id: Int64
    public let parentID: Int64
    public let rootID: Int64
    /// The first comment of the conversation this reply belongs to; 0 or `id` when none.
    public var dialogID: Int64 = 0
    public var authorID: Int64 = 0
    public let author: String
    public let avatar: URL?
    public var level: Int = 0
    /// Bilibili's name colour for 大会员, when the author has one.
    public var nameColor: String? = nil
    public var text: String
    public let likes: Int
    public let replyCount: Int
    public let date: Date
    public let replies: [Comment]
    public var pinned = false
    public var likedByUploader = false
    /// The signed-in viewer's action: 1 means liked; 0 and 2 do not.
    public var liked = false
    public var location: String? = nil
    /// Lines shown before 展开; Bilibili sends 6 for long comments.
    public var maxLines = 0
    public var pictures: [CommentPicture] = []
    /// Inline emote images keyed by their text, such as `[doge]`.
    public var emotes: [String: URL] = [:]
    /// Keywords Bilibili links to a search or page, keyed by the exact text.
    public var links: [String: CommentLink] = [:]
    /// Names after @ that refer to accounts.
    public var mentions: [String] = []

    public static func parse(_ value: [String: Any]) -> Comment? {
        guard let id = (value["rpid"] as? NSNumber)?.int64Value else { return nil }
        let member = value["member"] as? [String: Any] ?? [:]
        let content = value["content"] as? [String: Any] ?? [:]
        let control = value["reply_control"] as? [String: Any] ?? [:]
        let vip = member["vip"] as? [String: Any] ?? [:]
        var comment = Comment(
            id: id, parentID: (value["parent"] as? NSNumber)?.int64Value ?? 0,
            rootID: (value["root"] as? NSNumber)?.int64Value ?? 0,
            author: member["uname"] as? String ?? "用户",
            avatar: secureURL(member["avatar"] as? String ?? ""),
            text: content["message"] as? String ?? "",
            likes: (value["like"] as? NSNumber)?.intValue ?? 0,
            replyCount: (value["rcount"] as? NSNumber)?.intValue ?? 0,
            date: Date(timeIntervalSince1970: (value["ctime"] as? NSNumber)?.doubleValue ?? 0),
            replies: (value["replies"] as? [[String: Any]] ?? []).compactMap(parse))
        comment.dialogID = (value["dialog"] as? NSNumber)?.int64Value ?? 0
        comment.liked = (value["action"] as? NSNumber)?.intValue == 1
        comment.authorID =
            (value["mid"] as? NSNumber)?.int64Value
            ?? Int64(member["mid"] as? String ?? "") ?? 0
        comment.level =
            ((member["level_info"] as? [String: Any])?["current_level"] as? NSNumber)?
            .intValue ?? 0
        if (vip["vipStatus"] as? NSNumber)?.intValue == 1,
            let color = vip["nickname_color"] as? String, !color.isEmpty
        {
            comment.nameColor = color
        }
        comment.likedByUploader = (value["up_action"] as? [String: Any])?["like"] as? Bool ?? false
        comment.location = (control["location"] as? String).map {
            $0.replacingOccurrences(of: "IP属地：", with: "")
        }
        comment.maxLines = (control["max_line"] as? NSNumber)?.intValue ?? 0
        comment.pictures = (content["pictures"] as? [[String: Any]] ?? []).compactMap {
            guard let url = secureURL($0["img_src"] as? String ?? "") else { return nil }
            return CommentPicture(
                url: url, width: ($0["img_width"] as? NSNumber)?.doubleValue ?? 0,
                height: ($0["img_height"] as? NSNumber)?.doubleValue ?? 0)
        }
        for (key, emote) in content["emote"] as? [String: [String: Any]] ?? [:] {
            if let url = secureURL(emote["url"] as? String ?? "") { comment.emotes[key] = url }
        }
        for (key, link) in content["jump_url"] as? [String: [String: Any]] ?? [:] {
            let page = (link["pc_url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            comment.links[key] = page.map { .page($0) } ?? .search(link["title"] as? String ?? key)
        }
        comment.mentions = (content["members"] as? [[String: Any]] ?? []).compactMap {
            $0["uname"] as? String
        }
        return comment
    }
}

public struct CommentPicture: Hashable, Sendable {
    public let url: URL
    public let width: Double
    public let height: Double
}

public enum CommentLink: Hashable, Sendable {
    case search(String)
    case page(URL)
}

/// Pieces of a comment's text: plain runs, emotes, links, @mentions, video IDs and
/// timestamps such as 03:21, which the player can seek to.
public enum CommentSegment: Equatable, Sendable {
    case text(String)
    case emote(String, URL)
    case link(String, CommentLink)
    case mention(String)
    case video(String)
    case time(String, seconds: Double)

    public static func split(_ comment: Comment) -> [CommentSegment] {
        split(
            text: comment.text, emotes: comment.emotes, links: comment.links,
            mentions: comment.mentions)
    }

    /// Plain text such as a video description: BV IDs and timestamps only.
    public static func split(
        text: String, emotes: [String: URL] = [:], links: [String: CommentLink] = [:],
        mentions: [String] = []
    ) -> [CommentSegment] {
        var marks: [(Range<String.Index>, CommentSegment)] = []
        func add(_ needle: String, _ segment: CommentSegment) {
            var start = text.startIndex
            while let range = text.range(of: needle, range: start..<text.endIndex) {
                marks.append((range, segment))
                start = range.upperBound
            }
        }
        for (key, url) in emotes { add(key, .emote(key, url)) }
        for (key, link) in links { add(key, .link(key, link)) }
        for name in mentions { add("@" + name, .mention(name)) }
        let patterns: [(String, (String) -> CommentSegment?)] = [
            (#"BV[0-9A-Za-z]{10}"#, { .video($0) }),
            (
                #"(?<![0-9])(?<![0-9]:)(?:\d{1,2}:)?\d{1,2}:\d{2}(?![0-9]|:[0-9])"#,
                { token in
                    let parts = token.split(separator: ":").compactMap { Double($0) }
                    guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0 < 60 }) else {
                        return nil
                    }
                    return .time(token, seconds: parts.reduce(0) { $0 * 60 + $1 })
                }
            ),
        ]
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text), let segment = make(String(text[range]))
                {
                    marks.append((range, segment))
                }
            }
        }
        // Earlier and longer marks win; overlapping ones are dropped.
        marks.sort {
            $0.0.lowerBound != $1.0.lowerBound
                ? $0.0.lowerBound < $1.0.lowerBound : $0.0.upperBound > $1.0.upperBound
        }
        var segments: [CommentSegment] = []
        var cursor = text.startIndex
        for (range, segment) in marks where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(.text(String(text[cursor..<range.lowerBound])))
            }
            segments.append(segment)
            cursor = range.upperBound
        }
        if cursor < text.endIndex { segments.append(.text(String(text[cursor...]))) }
        return segments
    }
}

public struct CommentBranch: Identifiable, Sendable {
    public var id: Int64 { comment.id }
    public var comment: Comment { storage.comments[index] }
    public var children: [CommentBranch] {
        storage.children[index].map { CommentBranch(storage: storage, index: $0) }
    }
    public var descendantCount: Int { storage.descendants[index] }
    private let storage: CommentForest
    private let index: Int

    private init(storage: CommentForest, index: Int) {
        self.storage = storage
        self.index = index
    }

    /// API reply pages are flat. Only attach known parents; orphaned replies stay
    /// visible until a later page brings their parent into the loaded set.
    public static func forest(_ comments: [Comment], rootID: Int64) -> [CommentBranch] {
        let storage = CommentForest(comments, rootID: rootID)
        return storage.roots.map { CommentBranch(storage: storage, index: $0) }
    }
}

/// Shared flat storage avoids recursive construction and destruction for deep reply chains.
/// Each parent path is resolved once; descendant totals are accumulated from leaves to roots.
private final class CommentForest: Sendable {
    let comments: [Comment]
    let children: [[Int]]
    let descendants: [Int]
    let roots: [Int]

    init(_ comments: [Comment], rootID: Int64) {
        var seen = Set<Int64>()
        let unique = comments.filter { $0.id != rootID && seen.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: unique.indices.map { (unique[$0].id, $0) })
        var parents = unique.map { byID[$0.parentID] }
        // 0: unvisited, 1: on the current path, 2: acyclic, 3: reaches a cycle.
        var states = Array(repeating: UInt8(0), count: unique.count)
        for start in unique.indices where states[start] == 0 {
            var path: [Int] = []
            var next: Int? = start
            while let index = next, states[index] == 0 {
                states[index] = 1
                path.append(index)
                next = parents[index]
            }
            let acyclic = next.map { states[$0] == 2 } ?? true
            for index in path { states[index] = acyclic ? 2 : 3 }
        }
        var children = Array(repeating: [Int](), count: unique.count)
        var roots: [Int] = []
        for index in unique.indices {
            // As before, every reply leading into a cycle remains a visible root.
            if states[index] == 3 { parents[index] = nil }
            if let parent = parents[index] {
                children[parent].append(index)
            } else {
                roots.append(index)
            }
        }
        var descendants = Array(repeating: 0, count: unique.count)
        var remaining = children.map(\.count)
        var ready = unique.indices.filter { remaining[$0] == 0 }
        var cursor = 0
        while cursor < ready.count {
            let index = ready[cursor]
            cursor += 1
            if let parent = parents[index] {
                descendants[parent] += descendants[index] + 1
                remaining[parent] -= 1
                if remaining[parent] == 0 { ready.append(parent) }
            }
        }
        self.comments = unique
        self.children = children
        self.descendants = descendants
        self.roots = roots
    }
}
public struct CommentPage: Sendable {
    public let comments: [Comment]
    public let count: Int
    public let hasMore: Bool
    /// The uploader's account, so their comments can carry an UP badge.
    public var uploaderID: Int64 = 0
}

extension BilibiliAPI {
    public func likeComment(
        aid: Int64, replyID: Int64, liked: Bool, expectedUserID: Int64
    ) async throws {
        guard aid > 0, replyID > 0, expectedUserID > 0 else {
            throw APIError(code: -1, message: "评论或账号参数无效")
        }
        guard
            officialPlayerCookies().contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty })
        else { throw APIError(code: -101, message: "请先登录") }
        _ = try await request(
            "/x/v2/reply/action",
            form: [
                "type": "1", "oid": String(aid), "rpid": String(replyID),
                "action": liked ? "1" : "0",
            ], expectedUserID: expectedUserID)
    }

    public func videoRelation(bvid: String) async throws -> VideoRelation {
        VideoRelation(
            try await request("/x/web-interface/archive/relation", params: ["bvid": bvid]))
    }
    /// The coin count is newly added coins, not the viewer's total for the video.
    public func tripleVideo(aid: Int64, expectedUserID: Int64? = nil) async throws -> VideoRelation
    {
        guard aid > 0 else { throw APIError(code: -1, message: "视频参数无效") }
        try await ensureBrowserIdentifier()
        let data = try await request(
            "/x/web-interface/archive/like/triple", form: ["aid": String(aid)],
            expectedUserID: expectedUserID)
        return VideoRelation(
            liked: data["like"] as? Bool ?? false,
            coins: data["coin"] as? Bool == true
                ? max(0, min(2, (data["multiply"] as? NSNumber)?.intValue ?? 1)) : 0,
            favorited: data["fav"] as? Bool ?? false)
    }
    public func likeVideo(bvid: String, liked: Bool) async throws {
        _ = try await request(
            "/x/web-interface/archive/like", form: ["bvid": bvid, "like": liked ? "1" : "2"])
    }
    public func coinVideo(bvid: String, count: Int) async throws {
        guard (1...2).contains(count) else { throw APIError(code: -1, message: "投币数量无效") }
        _ = try await request(
            "/x/web-interface/coin/add",
            form: ["bvid": bvid, "multiply": String(count), "select_like": "0"])
    }
    public func related(bvid: String) async throws -> [Video] {
        // This endpoint returns an array in data; requestArray retains the common HTTP checks.
        return try await requestArray("/x/web-interface/archive/related", params: ["bvid": bvid])
            .compactMap(video)
    }
    public func comments(aid: Int64, page: Int = 1, newest: Bool = false, root: Int64? = nil)
        async throws -> CommentPage
    {
        var params = [
            "oid": String(aid), "type": "1", "pn": String(page), "ps": "20",
            "sort": newest ? "0" : "1",
        ]
        if let root { params["root"] = String(root) }
        let data = try await request(
            root == nil ? "/x/v2/reply" : "/x/v2/reply/reply", params: params)
        let info = data["page"] as? [String: Any] ?? [:]
        let count = (info["count"] as? NSNumber)?.intValue ?? 0
        var items = (data["replies"] as? [[String: Any]] ?? []).compactMap(Comment.parse)
        let upper = data["upper"] as? [String: Any] ?? [:]
        if page == 1, root == nil, let top = upper["top"] as? [String: Any],
            var comment = Comment.parse(top)
        {
            comment.pinned = true
            items.insert(comment, at: 0)
        }
        var seen = Set<Int64>()
        items = items.filter { seen.insert($0.id).inserted }
        var result = CommentPage(
            comments: items, count: count, hasMore: !items.isEmpty && page * 20 < count)
        result.uploaderID = (upper["mid"] as? NSNumber)?.int64Value ?? 0
        return result
    }
    /// One conversation inside a reply thread, in the order it was written.
    public func dialog(aid: Int64, root: Int64, dialog: Int64) async throws -> [Comment] {
        let data = try await request(
            "/x/v2/reply/dialog/cursor",
            params: [
                "oid": String(aid), "type": "1", "root": String(root), "dialog": String(dialog),
                "size": "20",
            ])
        return (data["replies"] as? [[String: Any]] ?? []).compactMap(Comment.parse)
    }
    public func ranking() async throws -> [Video] {
        let data = try await request(
            "/x/web-interface/ranking/v2", params: ["rid": "0", "type": "all"])
        return (data["list"] as? [[String: Any]] ?? []).compactMap(video)
    }
    public func recommended(page: Int = 1) async throws -> [Video] {
        let data = try await request(
            "/x/web-interface/wbi/index/top/feed/rcmd",
            params: [
                "fresh_type": "3", "ps": "20", "fresh_idx": String(page),
                "fresh_idx_1h": String(page), "feed_version": "V8", "homepage_ver": "1",
            ], signed: true)
        return (data["item"] as? [[String: Any]] ?? []).compactMap(video)
    }
}

/// One reply placed in a 评论详情 tree.
public struct CommentThreadRow: Identifiable, Sendable {
    public var id: Int64 { comment.id }
    /// The reply, with Bilibili's 「回复 @某人 :」 dropped when the tree already shows it.
    public let comment: Comment
    /// 1 for replies to the root comment.
    public let depth: Int
    /// Outer replies first, nearest last.
    public let ancestors: [Int64]
    /// Per ancestor: whether its branch line continues below this row, because the reply on
    /// this path is not that ancestor's last. The nearest one says whether this row has
    /// later siblings.
    public let rails: [Bool]
    /// Replies beneath this one, at any depth.
    public let descendants: Int
    public let collapsed: Bool
}

/// Builds Reddit-style trees from Bilibili's flat 楼中楼 replies using their parent IDs.
public enum CommentThread {
    /// Replies in depth-first order, built on `CommentBranch.forest`. A reply whose parent is
    /// not loaded starts a branch of its own and keeps its 回复 prefix; so do replies nested
    /// past `maxDepth`, which stop indenting there.
    public static func rows(
        root: Int64, replies: [Comment], collapsed: Set<Int64> = [], maxDepth: Int = 6
    ) -> [CommentThreadRow] {
        var rows: [CommentThreadRow] = []
        var pending = CommentBranch.forest(replies, rootID: root).reversed().map {
            (branch: $0, depth: 1, ancestors: [Int64](), rails: [Bool]())
        }
        while let next = pending.popLast() {
            let (branch, depth, ancestors, rails) = next
            var shown = branch.comment
            if depth > 1 && depth <= maxDepth { shown.text = stripReplyPrefix(shown.text) }
            let folded = collapsed.contains(branch.id)
            rows.append(
                CommentThreadRow(
                    comment: shown, depth: min(depth, maxDepth), ancestors: ancestors,
                    rails: rails, descendants: branch.descendantCount, collapsed: folded))
            guard !folded else { continue }
            let children = branch.children
            // Reverse the push order so the stack visits siblings in their input order.
            for (index, child) in children.enumerated().reversed() {
                let more = index < children.count - 1
                if depth < maxDepth {
                    pending.append(
                        (child, depth + 1, ancestors + [branch.id], rails + [more]))
                } else {
                    // At the limit children line up with their parent under the same line.
                    pending.append(
                        (
                            child, depth + 1, ancestors,
                            rails.dropLast() + [more || (rails.last ?? false)]
                        ))
                }
            }
        }
        return rows
    }

    /// Drops the leading 「回复 @某人 :」 Bilibili adds to replies within a thread.
    public static func stripReplyPrefix(_ text: String) -> String {
        guard
            let range = text.range(
                of: #"^回复\s*@[^:：\s]+\s*[:：]\s*"#, options: .regularExpression)
        else { return text }
        return String(text[range.upperBound...])
    }
}
