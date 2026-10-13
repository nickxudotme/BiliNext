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
    public init(
        bvid: String, title: String, author: String = "", cover: URL? = nil, avatar: URL? = nil,
        aid: Int64? = nil, duration: Double? = nil, progress: Double? = nil, viewedAt: Date? = nil,
        historyCID: Int64? = nil, ownerID: Int64? = nil, episodeID: Int64? = nil,
        viewCount: String? = nil, danmakuCount: String? = nil, pubdate: Date? = nil
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
    }
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
    public init(cid: Int64, number: Int, title: String) {
        self.cid = cid
        self.number = number
        self.title = title
    }
}
public struct VideoDetail: Sendable {
    public let video: Video
    public let pages: [VideoPage]
    public let description: String
    public init(video: Video, pages: [VideoPage], description: String) {
        self.video = video
        self.pages = pages
        self.description = description
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
