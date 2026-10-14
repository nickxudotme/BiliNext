import Foundation
import Testing

@testable import BiliNextCore

@Test func videoPageReadsUploaderTagsSeasonAndRelated() async throws {
    let body = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                #"""
                {"View":{"bvid":"BV1111111111","aid":1,"title":"第二集","desc":"简介","copyright":1,
                  "tname_v2":"游戏","rights":{"no_reprint":1},"pubdate":1760000000,
                  "owner":{"mid":7,"name":"UP","face":"http://i0.hdslb.com/f.jpg"},
                  "stat":{"view":100,"like":5},
                  "honor_reply":{"honor":[{"desc":"热门收录"}]},
                  "pages":[{"cid":11,"page":1,"part":"上","duration":61},{"cid":12,"page":2,"part":"下","duration":62}],
                  "ugc_season":{"id":9,"title":"系列","stat":{"view":4000},"sections":[
                    {"id":1,"title":"正片","episodes":[
                      {"bvid":"BV0000000001","aid":2,"cid":21,"title":"第一集","arc":{"pic":"http://i0.hdslb.com/1.jpg","duration":300,"stat":{"view":50}}},
                      {"bvid":"BV1111111111","aid":1,"cid":11,"title":"第二集","arc":{"duration":200}}]},
                    {"id":2,"title":"空","episodes":[]}]}},
                 "Card":{"follower":12345,"archive_count":88,"card":{"sign":"签名"}},
                 "Tags":[{"tag_name":"游戏"},{"tag_name":""},{"tag_name":"攻略"}],
                 "Related":[{"bvid":"BV2222222222","title":"相关","owner":{"name":"别人"}}]}
                """#.utf8)) as? [String: Any])
    let detail = try await BilibiliAPI(restoreSession: false).parseVideoPage(body)
    #expect(detail.pages.map(\.duration) == [61, 62])
    #expect(detail.extras.uploaderFollowers == 12345 && detail.extras.uploaderVideos == 88)
    #expect(detail.extras.uploaderSign == "签名" && detail.extras.tags == ["游戏", "攻略"])
    #expect(detail.extras.honors == ["热门收录"] && detail.extras.partition == "游戏")
    #expect(detail.extras.original && detail.extras.noReprint)
    let season = try #require(detail.extras.season)
    #expect(season.title == "系列" && season.views == 4000 && season.sections.count == 1)
    #expect(season.episodeCount == 2 && season.sections[0].episodes[0].views == 50)
    #expect(detail.extras.related.map(\.bvid) == ["BV2222222222"])
}
