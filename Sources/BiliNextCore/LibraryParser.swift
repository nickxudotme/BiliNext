import Foundation

enum LibraryParser {
    static func favorites(_ data: [String: Any], page: Int) -> Feed {
        let rows = data["medias"] as? [[String: Any]] ?? []
        return Feed(videos: rows.compactMap { row in
            // Folder resources can also be audio or PGC. This milestone handles UGC videos.
            guard (row["type"] as? NSNumber)?.intValue == 2 else { return nil }
            return parse(row, owner: row["upper"] as? [String: Any] ?? [:], aidKey: "id")
        }, next: data["has_more"] as? Bool == true ? String(page + 1) : nil)
    }
    static func watchLater(_ data: [String: Any], page: Int) -> Feed {
        let rows = data["list"] as? [[String: Any]] ?? []
        let count = (data["count"] as? NSNumber)?.intValue ?? 0
        return Feed(videos: rows.compactMap { parse($0, owner: $0["owner"] as? [String: Any] ?? [:], aidKey: "aid") }, next: !rows.isEmpty && page * 20 < count ? String(page + 1) : nil)
    }
    static func history(_ data: [String: Any], previousCursor: String?) -> Feed {
        let rows = data["list"] as? [[String: Any]] ?? []
        let videos: [Video] = rows.compactMap { row in
            let history = row["history"] as? [String: Any] ?? [:]
            guard history["business"] as? String == "archive", let bvid = history["bvid"] as? String, !bvid.isEmpty else { return nil }
            return Video(bvid: bvid, title: row["title"] as? String ?? "视频已失效", author: row["author_name"] as? String ?? "", cover: secureURL(row["cover"] as? String ?? ""), avatar: secureURL(row["author_face"] as? String ?? ""), aid: (history["oid"] as? NSNumber)?.int64Value, duration: (row["duration"] as? NSNumber)?.doubleValue, progress: (row["progress"] as? NSNumber)?.doubleValue, viewedAt: (row["view_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }, historyCID: (history["cid"] as? NSNumber)?.int64Value)
        }
        var next: String?
        if !rows.isEmpty, let cursor = data["cursor"] as? [String: Any], let max = cursor["max"] as? NSNumber, max.int64Value != 0 {
            let value = ["max": max.stringValue, "view_at": (cursor["view_at"] as? NSNumber)?.stringValue ?? "0", "business": cursor["business"] as? String ?? "archive"]
            if let encoded = try? JSONEncoder.sorted.encode(value) { next = String(data: encoded, encoding: .utf8) }
        }
        if next == previousCursor { next = nil }
        return Feed(videos: videos, next: next)
    }
    private static func parse(_ row: [String: Any], owner: [String: Any], aidKey: String) -> Video? {
        guard let bvid = row["bvid"] as? String ?? row["bv_id"] as? String, !bvid.isEmpty else { return nil }
        return Video(bvid: bvid, title: row["title"] as? String ?? "视频已失效", author: owner["name"] as? String ?? "", cover: secureURL(row["pic"] as? String ?? row["cover"] as? String ?? ""), avatar: secureURL(owner["face"] as? String ?? ""), aid: (row[aidKey] as? NSNumber)?.int64Value, duration: (row["duration"] as? NSNumber)?.doubleValue)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder }
}
