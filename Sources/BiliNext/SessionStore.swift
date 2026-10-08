import BiliNextCore
import Foundation

struct SessionTab: Identifiable, Codable {
    var id: String { video.bvid }
    var video: Video
    var cid: Int64?
    var position: Double = 0
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
