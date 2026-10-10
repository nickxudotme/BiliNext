import Foundation
import Testing

@testable import BiliNextCore

@Test func cardsReadNumericAndSearchMetadataWithoutInventingCounts() async throws {
    let api = BilibiliAPI(restoreSession: false)
    let search = try #require(
        await api.video([
            "bvid": "BV1111111111", "title": "<em>4K</em> 风景", "duration": "4:05",
            "play": 12345, "video_review": 67,
        ]))
    #expect(search.title == "4K 风景")
    #expect(search.duration == 245)
    #expect(search.viewCount == "12345" && search.danmakuCount == "67")
    let detail = try #require(
        await api.video([
            "bvid": "BV2222222222", "duration": 120,
            "stat": ["view": 98765, "danmaku": 432],
        ]))
    #expect(detail.duration == 120)
    #expect(detail.viewCount == "98765" && detail.danmakuCount == "432")
    let feed = try #require(
        await api.video([
            "bvid": "BV4444444444", "duration_text": "12:34",
            "stat": ["play": "1.2万", "danmaku": "89"],
        ]))
    #expect(feed.duration == 754)
    #expect(feed.viewCount == "1.2万" && feed.danmakuCount == "89")
    let missing = try #require(await api.video(["bvid": "BV3333333333"]))
    #expect(missing.viewCount == nil && missing.danmakuCount == nil)
    let legacy = Data(#"{"bvid":"BV1111111111","title":"旧标签","author":"UP"}"#.utf8)
    let restored = try JSONDecoder().decode(Video.self, from: legacy)
    #expect(restored.viewCount == nil && restored.danmakuCount == nil)
}
