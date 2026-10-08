import Testing
import Foundation
@testable import BiliNextCore

@Test func signatureCanonicalization() throws {
    let key = try WBISigner.mixinKey(image: "7cd084941338484aae1ad9425b84077c", sub: "4932caff0ff746eab6f01bf08b70ac45")
    #expect(key == "ea1db124af3c7062474693fa704f4ff8")
    let signed = WBISigner.sign(["foo": "114", "bar": "514", "baz": "1919810"], key: key, timestamp: 1702204169)
    #expect(signed["w_rid"] == "6149fdadf571698ca7e6a567265cd0ee")
    #expect(WBISigner.query(["q": "中 文+"]) == "q=%E4%B8%AD%20%E6%96%87%2B")
    #expect(WBISigner.sign(["q": "a!'()*b"], key: key, timestamp: 0)["q"] == "ab")
}

@Test func subtitleOverlapsAndGaps() {
    let cues = [Cue(id: 0, start: 1, end: 3, text: "第一句"), Cue(id: 1, start: 2, end: 4, text: "重叠"), Cue(id: 2, start: 8, end: 9, text: "停顿以后")]
    #expect(cues.filter { $0.contains(2.5) }.map(\.id) == [0, 1])
    #expect(cues.filter { $0.contains(4) }.isEmpty)
    let groups = Cue.paragraphs(cues)
    #expect(groups.map { $0.map(\.id) } == [[0, 1], [2]])
    #expect(groups.flatMap { $0 } == cues)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_LIVE_TEST"] == "1"))
func publicAPISmoke() async throws {
    let api = BilibiliAPI(restoreSession: false)
    let videos = try await api.popular()
    let first = try #require(videos.first)
    let detail = try await api.detail(first.bvid)
    #expect(detail.video.bvid == first.bvid)
    let page = try #require(detail.pages.first)
    let playback = try await api.playback(bvid: first.bvid, cid: page.cid)
    #expect(playback.url.scheme == "https")
    _ = try await api.subtitleTracks(bvid: first.bvid, cid: page.cid)
}

@Test func historyPaginationKeepsCursorEvenForNonVideoRows() {
    let cursor: [String: Any] = ["max": 19, "view_at": 123, "business": "archive"]
    let response: [String: Any] = ["list": [["title": "直播", "history": ["business": "live", "bvid": ""]]], "cursor": cursor]
    let first = LibraryParser.history(response, previousCursor: nil)
    #expect(first.videos.isEmpty)
    #expect(first.next != nil)
    #expect(LibraryParser.history(response, previousCursor: first.next).next == nil)
}

@Test func cloudHistoryPreservesPartAndCompletedSentinel() {
    let data: [String: Any] = ["list": [["title": "样例", "progress": -1, "view_at": 123, "history": ["business": "archive", "bvid": "BV1234567890", "cid": 42, "oid": 12]]]]
    let result = LibraryParser.history(data, previousCursor: nil)
    #expect(result.videos.first?.progress == -1)
    #expect(result.videos.first?.historyCID == 42)
    #expect(result.next == nil)
}

@Test func libraryResponseShapesAndPagination() {
    let media: [String: Any] = ["type": 2, "id": 12, "bvid": "BV1234567890", "upper": ["name": "作者"], "title": "样例"]
    let favorites = LibraryParser.favorites(["medias": [media, ["type": 12]], "has_more": true], page: 1)
    #expect(favorites.videos.count == 1)
    #expect(favorites.videos.first?.author == "作者")
    #expect(favorites.next == "2")
    let later = LibraryParser.watchLater(["list": [["bvid": "BV1234567890", "aid": 12]], "count": 21], page: 1)
    #expect(later.next == "2")
    #expect(LibraryParser.watchLater(["list": [], "count": 21], page: 2).next == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_AUTH_TEST"] == "1"))
func authenticatedLibrarySmoke() async throws {
    #if DEBUG
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    #else
    let api = BilibiliAPI()
    #endif
    let me = try await api.profile()
    let folders = try await api.favoriteFolders(mid: me.id)
    if let first = folders.first { _ = try await api.favorites(folder: first.id, page: 1) }
    _ = try await api.watchLater(page: 1)
    let history = try await api.watchHistory(cursor: nil)
    if let cursor = history.next { _ = try await api.watchHistory(cursor: cursor) }
    _ = try await api.feed()
}

#if DEBUG
@Test func developmentStoragePermissionsAndLogout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DevelopmentSessionStore(directory: directory)
    #expect(try store.read() == nil)
    let fixture = Data("[{\"test\":true}]".utf8)
    try store.write(fixture)
    #expect(try store.read() == fixture)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    let file = try FileManager.default.attributesOfItem(atPath: store.file.path)
    #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try store.clear()
    #expect(try store.read() == Data("[]".utf8))
}
#endif
