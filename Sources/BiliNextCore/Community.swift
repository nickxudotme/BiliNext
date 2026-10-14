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
                    guard parts.count >= 2, parts.last! < 60 else { return nil }
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
                if !ancestors.insert(candidate).inserted {
                    valid = false
                    break
                }
                candidate = parent.parentID
            }
            if valid, byID[comment.parentID] != nil { parents[comment.id] = comment.parentID }
        }
        let children = Dictionary(
            grouping: unique.filter { parents[$0.id] != nil }, by: { parents[$0.id]! })
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
    /// The uploader's account, so their comments can carry an UP badge.
    public var uploaderID: Int64 = 0
}

extension BilibiliAPI {
    public func videoRelation(bvid: String) async throws -> VideoRelation {
        VideoRelation(
            try await request("/x/web-interface/archive/relation", params: ["bvid": bvid]))
    }
    /// 一键三连: like, two coins where allowed, and favorite to the default folder.
    public func tripleVideo(aid: Int64) async throws -> VideoRelation {
        let data = try await request(
            "/x/web-interface/archive/like/triple", form: ["aid": String(aid)])
        return VideoRelation(
            liked: data["like"] as? Bool ?? false,
            coins: (data["multiply"] as? NSNumber)?.intValue
                ?? (data["coin"] as? Bool == true ? 1 : 0),
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
        func visit(_ branch: CommentBranch, depth: Int, ancestors: [Int64], rails: [Bool]) {
            var shown = branch.comment
            if depth > 1 && depth <= maxDepth { shown.text = stripReplyPrefix(shown.text) }
            let folded = collapsed.contains(branch.id)
            rows.append(
                CommentThreadRow(
                    comment: shown, depth: min(depth, maxDepth), ancestors: ancestors,
                    rails: rails, descendants: branch.descendantCount, collapsed: folded))
            guard !folded else { return }
            for (index, child) in branch.children.enumerated() {
                let more = index < branch.children.count - 1
                if depth < maxDepth {
                    visit(
                        child, depth: depth + 1, ancestors: ancestors + [branch.id],
                        rails: rails + [more])
                } else {
                    // At the limit children line up with their parent under the same line.
                    visit(
                        child, depth: depth + 1, ancestors: ancestors,
                        rails: rails.dropLast() + [more || (rails.last ?? false)])
                }
            }
        }
        for branch in CommentBranch.forest(replies, rootID: root) {
            visit(branch, depth: 1, ancestors: [], rails: [])
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
