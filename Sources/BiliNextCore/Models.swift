import Foundation

public struct Video: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bvid }
    public let bvid: String
    public let title: String
    public let author: String
    public let cover: URL?
    public let avatar: URL?
    public let aid: Int64?
    public let duration: Double?
    public let progress: Double?
    public let viewedAt: Date?
    public let historyCID: Int64?
    public let ownerID: Int64?
    public let episodeID: Int64?
    public let viewCount: String?
    public let danmakuCount: String?
    public let pubdate: Date?
    /// The first part's cid when a list provides it, so playback can start without the
    /// detail request.
    public let cid: Int64?
    public init(
        bvid: String, title: String, author: String = "", cover: URL? = nil, avatar: URL? = nil,
        aid: Int64? = nil, duration: Double? = nil, progress: Double? = nil, viewedAt: Date? = nil,
        historyCID: Int64? = nil, ownerID: Int64? = nil, episodeID: Int64? = nil,
        viewCount: String? = nil, danmakuCount: String? = nil, pubdate: Date? = nil,
        cid: Int64? = nil
    ) {
        self.bvid = bvid
        self.title = title
        self.author = author
        self.cover = cover
        self.avatar = avatar
        self.aid = aid
        self.duration = duration
        self.progress = progress
        self.viewedAt = viewedAt
        self.historyCID = historyCID
        self.ownerID = ownerID
        self.episodeID = episodeID
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.pubdate = pubdate
        self.cid = cid
    }
    /// The part playback will most likely open: a known history part, else the listed first.
    public var playableCID: Int64? { historyCID ?? cid }

    public static func extractBVID(_ text: String) -> String? {
        guard let range = text.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }
}
public struct VideoPage: Identifiable, Sendable {
    public var id: Int64 { cid }
    public let cid: Int64
    public let number: Int
    public let title: String
    public var duration: Double = 0
    public init(cid: Int64, number: Int, title: String, duration: Double = 0) {
        self.cid = cid
        self.number = number
        self.title = title
        self.duration = duration
    }
}
public struct VideoDetail: Sendable {
    public let video: Video
    public let pages: [VideoPage]
    public let description: String
    public var stats: VideoStats
    /// What the official video page shows around the player; empty when only `/view` loaded.
    public var extras = VideoExtras()
    public init(
        video: Video, pages: [VideoPage], description: String, stats: VideoStats = VideoStats()
    ) {
        self.video = video
        self.pages = pages
        self.description = description
        self.stats = stats
    }
}

public struct VideoExtras: Sendable {
    public var uploaderFollowers: Int?
    public var uploaderVideos: Int?
    public var uploaderSign = ""
    public var tags: [String] = []
    /// Badges such as 全站排行榜最高第29名 or 热门收录.
    public var honors: [String] = []
    public var partition = ""
    /// 1 is the uploader's own work; reposts show their source.
    public var original = true
    public var noReprint = false
    public var season: VideoSeason?
    public var related: [Video] = []
    public init() {}
}

/// A UGC 合集: named sections of episodes, each its own video.
public struct VideoSeason: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let cover: URL?
    public let views: Int?
    public let sections: [Section]
    public var episodeCount: Int { sections.reduce(0) { $0 + $1.episodes.count } }

    public struct Section: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let episodes: [Episode]
    }

    public struct Episode: Identifiable, Sendable {
        public var id: String { bvid }
        public let bvid: String
        public let aid: Int64?
        public let cid: Int64?
        public let title: String
        public let cover: URL?
        public let duration: Double
        public let views: Int?
        public let pubdate: Date?
        public let author: String
    }

    public init(id: Int64, title: String, cover: URL?, views: Int?, sections: [Section]) {
        self.id = id
        self.title = title
        self.cover = cover
        self.views = views
        self.sections = sections
    }
}

/// Public counters from the video page; nil when the response omits one.
public struct VideoStats: Equatable, Sendable {
    public var likes: Int?
    public var coins: Int?
    public var favorites: Int?
    public var shares: Int?
    public var replies: Int?
    public init(
        likes: Int? = nil, coins: Int? = nil, favorites: Int? = nil, shares: Int? = nil,
        replies: Int? = nil
    ) {
        self.likes = likes
        self.coins = coins
        self.favorites = favorites
        self.shares = shares
        self.replies = replies
    }

    public init(stat: [String: Any]) {
        func value(_ key: String) -> Int? { (stat[key] as? NSNumber)?.intValue }
        self.init(
            likes: value("like"), coins: value("coin"), favorites: value("favorite"),
            shares: value("share"), replies: value("reply"))
    }
}

/// The signed-in account's like, coin and favorite state for one video.
public struct VideoRelation: Equatable, Sendable {
    public var liked: Bool
    public var coins: Int
    public var favorited: Bool
    public init(liked: Bool = false, coins: Int = 0, favorited: Bool = false) {
        self.liked = liked
        self.coins = coins
        self.favorited = favorited
    }

    public init(_ data: [String: Any]) {
        self.init(
            liked: data["like"] as? Bool ?? false,
            coins: (data["coin"] as? NSNumber)?.intValue ?? 0,
            favorited: data["favorite"] as? Bool ?? false)
    }
}
public struct SubtitleTrack: Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let language: String
    public let url: URL
}
public struct Cue: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let text: String
    public init(id: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
    public func contains(_ time: Double) -> Bool { start <= time && time < end }
    public static func paragraphs(_ cues: [Cue]) -> [[Cue]] {
        var result: [[Cue]] = []
        var current: [Cue] = []
        for cue in cues {
            if let last = current.last,
                cue.start - last.end > 2 || current.map(\.text).joined().count >= 180
            {
                result.append(current)
                current = []
            }
            current.append(cue)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
public struct Feed: Sendable {
    public let videos: [Video]
    public let next: String?
}
public struct FavoriteFolder: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let count: Int
}
public struct LoginCode: Sendable {
    public let url: String
    public let key: String
}
public enum LoginStatus: Sendable { case waiting, scanned, expired, success }
public struct UserProfile: Sendable {
    public let id: Int64
    public let name: String
}
public struct PlaybackQuality: Identifiable, Sendable {
    public var id: Int { value }
    public let value: Int
    public let label: String
}
public struct Playback: Sendable {
    public let url: URL
    public let quality: String
    public let qualityID: Int
    public let qualities: [PlaybackQuality]
    public let videoStream: PlaybackStream?
    public let audioStream: PlaybackStream?
}
public struct PlaybackStream: Sendable {
    public let urls: [URL]
    public let codec: String
    public let bandwidth: Int
    public let initialization: ClosedRange<Int64>
    public let index: ClosedRange<Int64>
}
public struct APIError: LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? {
        if code == -101 { return "登录已失效，请重新扫码登录。" }
        if code == 412 || code == -412 { return "B 站暂时限制了此请求（412）。请登录后稍候重试。" }
        return "\(message)（\(code)）"
    }
}
public func secureURL(_ text: String) -> URL? {
    guard !text.isEmpty else { return nil }
    let value =
        text.hasPrefix("//")
        ? "https:" + text : text.replacingOccurrences(of: "http://", with: "https://")
    guard let url = URL(string: value), url.scheme == "https" else { return nil }
    return url
}
public func timestamp(_ seconds: Double) -> String {
    let value = Int(max(0, seconds.isFinite ? seconds : 0))
    return value >= 3600
        ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

/// One 看点 chapter the uploader marked on the timeline.
public struct ViewPoint: Sendable, Equatable, Identifiable {
    public var id: Double { start }
    public let start: Double
    public let end: Double
    public let title: String
    public let image: URL?

    public init(start: Double, end: Double, title: String, image: URL? = nil) {
        self.start = start
        self.end = end
        self.title = title
        self.image = image
    }

    /// The chapter playing at `seconds`, if any.
    public static func containing(_ seconds: Double, in points: [ViewPoint]) -> ViewPoint? {
        points.last { $0.start <= seconds && seconds < $0.end }
    }
}

public struct PlayerInfo: Sendable {
    public let subtitles: [SubtitleTrack]
    public let viewPoints: [ViewPoint]
}
