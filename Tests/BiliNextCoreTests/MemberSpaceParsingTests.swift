import Foundation
import Testing

@testable import BiliNextCore

private func json(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

@Test func memberCardReadsIdentityStatsAndBanner() async throws {
    let data = try json(
        #"""
        {"card":{"mid":"7","name":"UP","face":"http://i0.hdslb.com/face.jpg","sign":"签名",
          "level_info":{"current_level":6},"attention":12,"fans":99,
          "Official":{"type":0,"title":"知名游戏 UP 主"},
          "vip":{"vipStatus":1,"label":{"text":"年度大会员"}}},
         "space":{"s_img":"http://i0.hdslb.com/s.png","l_img":"http://i0.hdslb.com/l.png"},
         "following":true,"archive_count":680,"follower":20842221,"like_num":530000000}
        """#)
    let card = await BilibiliAPI(restoreSession: false).parseMemberCard(data, mid: 7)
    #expect(card.name == "UP" && card.signature == "签名" && card.level == 6)
    #expect(card.avatar?.scheme == "https" && card.banner?.lastPathComponent == "l.png")
    #expect(card.official == "知名游戏 UP 主" && card.officialKind == 0)
    #expect(card.vipLabel == "年度大会员" && card.following)
    #expect(card.followers == 20_842_221 && card.followings == 12)
    #expect(card.likes == 530_000_000 && card.videos == 680)

    let plain = await BilibiliAPI(restoreSession: false).parseMemberCard(
        try json(#"{"card":{"name":"新人","vip":{"vipStatus":0,"label":{"text":"大会员"}}}}"#),
        mid: 8)
    #expect(plain.vipLabel.isEmpty && plain.official.isEmpty && plain.officialKind == -1)
    #expect(plain.banner == nil && !plain.following)
}

@Test func memberCollectionsListSeasonsBeforeSeries() throws {
    let data = try json(
        #"""
        {"items_lists":{"page":{"page_num":1,"page_size":2,"total":3},
          "seasons_list":[{"meta":{"season_id":11,"name":"合集·实况","title":"实况","cover":"https://a/1.jpg",
            "total":23,"ptime":1790000000},"archives":[]}],
          "series_list":[{"meta":{"series_id":22,"name":"旅行","cover":"http://a/2.jpg",
            "total":13,"mtime":1780000000},"archives":[]},
           {"meta":{"name":"无编号"}}]}}
        """#)
    let result = BilibiliAPI.parseCollections(data, page: 1)
    #expect(result.collections.map(\.id) == ["season:11", "series:22"])
    #expect(result.collections.map(\.title) == ["实况", "旅行"])
    #expect(result.collections[1].cover?.scheme == "https" && result.collections[0].count == 23)
    #expect(result.collections[0].updated != nil && result.hasMore)
}

@Test func spaceUploadsReadTheAuthorObject() async throws {
    let item = try json(
        #"""
        {"bvid":"BV1iqpt6cEMU","aid":1,"title":"投稿","pic":"http://i0.hdslb.com/c.jpg",
         "duration":2893,"pubdate":1791613800,
         "author":{"mid":546195,"name":"老番茄","face":"http://i0.hdslb.com/f.jpg"},
         "stat":{"view":2610183,"danmaku":10840}}
        """#)
    let video = try #require(await BilibiliAPI(restoreSession: false).video(item))
    #expect(video.author == "老番茄" && video.ownerID == 546195)
    #expect(video.viewCount == "2610183" && video.duration == 2893 && video.pubdate != nil)
}
