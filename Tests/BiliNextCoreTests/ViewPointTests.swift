import Foundation
import Testing

@testable import BiliNextCore

@Test func playerInfoReadsChaptersAndSubtitles() throws {
    let data = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                #"""
                {"subtitle":{"subtitles":[{"lan_doc":"中文","subtitle_url":"//aisubtitle.hdslb.com/a.json"}]},
                 "view_points":[
                   {"type":2,"from":41,"to":86,"content":"羌塘","imgUrl":"http://i0.hdslb.com/bfs/vchapter/1_41.jpg"},
                   {"type":2,"from":0,"to":41,"content":" 引言 "},
                   {"type":1,"from":90,"to":95,"content":"高能"},
                   {"type":2,"from":86,"to":86,"content":"空"},
                   {"type":2,"from":86,"to":224,"content":""}]}
                """#.utf8)) as? [String: Any])
    let info = BilibiliAPI.parsePlayerInfo(data)
    #expect(info.subtitles.map(\.language) == ["中文"])
    #expect(info.viewPoints.map(\.title) == ["引言", "羌塘", "章节"])
    #expect(info.viewPoints[1].image?.scheme == "https")
    #expect(ViewPoint.containing(50, in: info.viewPoints)?.title == "羌塘")
    #expect(ViewPoint.containing(86, in: info.viewPoints)?.title == "章节")
    #expect(ViewPoint.containing(300, in: info.viewPoints) == nil)
}

@Test func relationReadsWhetherTheUploaderIsFollowed() {
    let relation = VideoRelation(["like": true, "coin": 1, "favorite": false, "attention": true])
    #expect(relation.liked && relation.coins == 1 && !relation.favorited && relation.following)
    #expect(!VideoRelation([:]).following)
}

@Test func videoShotsLocateFramesAcrossSheets() throws {
    let data: [String: Any] = [
        "image": ["//bimp.hdslb.com/a-0001.jpg", "//bimp.hdslb.com/a-0002.jpg"],
        "img_x_len": 10, "img_y_len": 10, "img_x_size": 480, "img_y_size": 270,
        "index": (0..<150).map { $0 * 5 },
    ]
    let shots = try #require(BilibiliAPI.parseVideoShots(data))
    #expect(shots.sheets.first?.scheme == "https")
    #expect(shots.frame(at: 0).map { [$0.sheet, $0.column, $0.row] } == [0, 0, 0])
    #expect(shots.frame(at: 58).map { [$0.sheet, $0.column, $0.row] } == [0, 1, 1])
    #expect(shots.frame(at: 504).map { [$0.sheet, $0.column, $0.row] } == [1, 0, 0])
    #expect(shots.frame(at: 10_000).map { [$0.sheet, $0.column, $0.row] } == [1, 9, 4])
    #expect(BilibiliAPI.parseVideoShots(["image": [String]()]) == nil)
}
