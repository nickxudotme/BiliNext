import BiliNextCore
import Foundation

struct SessionTab: Identifiable, Codable {
    var id: String { video.bvid }
    var video: Video
    var cid: Int64?
    var position: Double = 0
    /// The videos this tab moved through in place, for 后退 and 前进. Like a browser tab's
    /// history it is saved with the tab, survives restarts and returns with ⇧⌘T.
    var trail = TabTrail()

    init(video: Video, cid: Int64? = nil, position: Double = 0, trail: TabTrail = TabTrail()) {
        self.video = video
        self.cid = cid
        self.position = position
        self.trail = trail
    }

    init(_ entry: TabHistoryEntry, trail: TabTrail) {
        self.init(video: entry.video, cid: entry.cid, position: entry.position, trail: trail)
    }

    // Sessions written before tab history existed have no trail.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        video = try container.decode(Video.self, forKey: .video)
        cid = try container.decodeIfPresent(Int64.self, forKey: .cid)
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        trail = try container.decodeIfPresent(TabTrail.self, forKey: .trail) ?? TabTrail()
    }
}

/// One video in a tab's history, where it was left.
struct TabHistoryEntry: Codable, Equatable {
    var video: Video
    var cid: Int64?
    var position: Double

    init(_ tab: SessionTab) {
        video = tab.video
        cid = tab.cid
        position = tab.position
    }
}

/// A tab's in-place navigation history, nearest last on each side.
struct TabTrail: Codable, Equatable {
    var back: [TabHistoryEntry] = []
    var forward: [TabHistoryEntry] = []

    /// Each side keeps at most this many videos; the oldest fall off.
    static let limit = 100

    /// Records leaving `current` for a different video: it joins the back side and the
    /// forward side is discarded, as when following a link.
    mutating func leave(_ current: SessionTab) {
        back.append(TabHistoryEntry(current))
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
    }

    /// Moves one video back (`delta < 0`) or forward from `current`, which joins the other
    /// side. Nil when there is nothing that way.
    mutating func step(_ delta: Int, from current: SessionTab) -> TabHistoryEntry? {
        if delta < 0, let previous = back.popLast() {
            forward.append(TabHistoryEntry(current))
            return previous
        }
        if delta > 0, let next = forward.popLast() {
            back.append(TabHistoryEntry(current))
            return next
        }
        return nil
    }
}

/// Persists tab records; AppModel owns recovery policy and save timing.
struct SessionStore {
    let file: URL

    init(
        directory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("BiliNext", isDirectory: true)
    ) {
        file = directory.appendingPathComponent("session.json")
    }

    func read() throws -> [SessionTab] {
        try JSONDecoder().decode([SessionTab].self, from: Data(contentsOf: file))
    }

    func write(_ tabs: [SessionTab]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tabs).write(to: file, options: .atomic)
    }
}
