import Foundation
import Testing

@testable import BiliNextCore

@Test func protobufDanmakuAndMalformedInput() throws {
    // id=1, progress=1500 ms, mode=5, content=Hi, id_str=123.
    let element: [UInt8] = [8, 1, 16, 220, 11, 24, 5, 58, 2, 72, 105, 98, 3, 49, 50, 51]
    let result = try DanmakuDecoder.decode(Data([10, UInt8(element.count)] + element))
    #expect(result.count == 1)
    #expect(result.first?.time == 1.5)
    #expect(result.first?.id == "123")
    #expect(result.first?.mode == 5)
    #expect(result.first?.text == "Hi")
    #expect(throws: (any Error).self) { try DanmakuDecoder.decode(Data([10, 255])) }
    #expect(throws: (any Error).self) { try DanmakuDecoder.decode(Data(repeating: 255, count: 11)) }
    #expect(try DanmakuDecoder.decode(Data()).isEmpty)
}

@Test func scrollingDanmakuCannotCatchUp() {
    let items = [
        Danmaku(id: "1", time: 0, mode: 1, text: "short"),
        Danmaku(id: "2", time: 1, mode: 1, text: "long"),
        Danmaku(id: "3", time: 7, mode: 1, text: "long"),
    ]
    let result = DanmakuLayout.arrange(items, viewport: 600, lanes: 1, duration: 8) {
        $0.text == "short" ? 80 : 500
    }
    #expect(result.map(\.id) == ["1", "3"])
    #expect(result[0].visible(at: 0))
    #expect(!result[0].visible(at: 8))
    #expect(result[0].x(at: 0, viewport: 600) == 600)
    #expect(result[0].x(at: 8, viewport: 600) == -80)
}

#if DEBUG
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_AUTH_TEST"] == "1"))
    func viewingAPISmoke() async throws {
        let api = BilibiliAPI(credentialStorage: .developmentFile)
        let detail = try await api.detail("BV1GJ411x7h7")
        let page = try #require(detail.pages.first)
        let comments = try await api.danmaku(cid: page.cid, segment: 1)
        #expect(!comments.isEmpty)
        #expect(comments.allSatisfy { $0.time >= 0 && $0.time <= 360 })
        _ = try await api.videoRelation(bvid: detail.video.bvid)
        let aid = try #require(detail.video.aid)
        let replies = try await api.comments(aid: aid)
        #expect(!replies.comments.isEmpty)
        if let root = replies.comments.first(where: { $0.replyCount > 0 }) {
            _ = try await api.comments(aid: aid, root: root.id)
        }
        #expect(try await !api.related(bvid: detail.video.bvid).isEmpty)
        #expect(try await !api.recommended().isEmpty)
        #expect(try await !api.ranking().isEmpty)
        let me = try await api.profile()
        _ = try await api.favoriteSelection(mid: me.id, aid: aid)
        let owner = try #require(detail.video.ownerID)
        _ = try await api.member(mid: owner)
        #expect(try await !api.memberVideos(mid: owner).videos.isEmpty)
    }
#endif

#if DEBUG
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_AUTH_TEST"] == "1"))
    func seasonAndLibrarySearchSmoke() async throws {
        let api = BilibiliAPI(credentialStorage: .developmentFile)
        let seasons = try await api.seasons(type: 4)
        let first = try #require(seasons.first)
        let detail = try await api.season(id: first.id)
        #expect(!detail.episodes.isEmpty)
        #expect(detail.episodes.allSatisfy { $0.episodeID != nil && $0.historyCID != nil })
        let episode = try #require(detail.episodes.first)
        let media = try await api.playback(
            bvid: episode.bvid, cid: episode.historyCID!, episodeID: episode.episodeID)
        var probe = URLRequest(url: media.url)
        probe.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        probe.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        probe.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: probe)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(bytes.count == 1024)
        let activities = try await api.activities()
        #expect(!activities.items.isEmpty)
        if let cursor = activities.next { _ = try await api.activities(offset: cursor) }
        _ = try await api.searchHistory(keyword: "Swift", page: 1)
        let me = try await api.profile()
        let folders = try await api.favoriteFolders(mid: me.id)
        if let first = folders.first {
            _ = try await api.favorites(
                folder: first.id, page: 1, keyword: "Swift", order: "pubtime")
        }
    }
#endif
