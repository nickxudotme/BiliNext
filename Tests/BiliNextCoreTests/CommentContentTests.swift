import Foundation
import Testing

@testable import BiliNextCore

private func comment(_ json: String) throws -> BiliNextCore.Comment {
    let value = try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return try #require(BiliNextCore.Comment.parse(value))
}

@Test func commentsReadIdentityPicturesAndRichContent() throws {
    let parsed = try comment(
        #"""
        {"rpid":3,"parent":1,"root":1,"dialog":2,"mid":42,"like":12,"rcount":0,"ctime":1760000000,
         "member":{"uname":"阿B","avatar":"http://i0.hdslb.com/a.jpg","level_info":{"current_level":6},
                   "vip":{"vipStatus":1,"nickname_color":"#FB7299"}},
         "up_action":{"like":true},
         "reply_control":{"location":"IP属地：上海","max_line":6},
         "content":{"message":"回复 @小明 :03:21 笑死[doge] 看 BV1xx411c7mD 和枯木逢春",
           "pictures":[{"img_src":"http://i0.hdslb.com/p.jpg","img_width":800,"img_height":600}],
           "emote":{"[doge]":{"url":"http://i0.hdslb.com/doge.png"}},
           "jump_url":{"枯木逢春":{"title":"枯木逢春","pc_url":""}},
           "members":[{"uname":"小明","mid":"7"}]}}
        """#)
    #expect(parsed.dialogID == 2 && parsed.authorID == 42 && parsed.level == 6)
    #expect(parsed.nameColor == "#FB7299" && parsed.likedByUploader)
    #expect(parsed.location == "上海" && parsed.maxLines == 6)
    #expect(parsed.pictures.first?.url.absoluteString == "https://i0.hdslb.com/p.jpg")
    #expect(
        CommentSegment.split(parsed) == [
            .text("回复 "), .mention("小明"), .text(" :"), .time("03:21", seconds: 201),
            .text(" 笑死"), .emote("[doge]", URL(string: "https://i0.hdslb.com/doge.png")!),
            .text(" 看 "), .video("BV1xx411c7mD"), .text(" 和"), .link("枯木逢春", .search("枯木逢春")),
        ])
}

@Test func timestampsNeedValidSecondsAndStandAlone() throws {
    let parsed = try comment(
        #"{"rpid":1,"member":{},"content":{"message":"1:02:03 和 12:75 和 2024:10:01 还有 9:05"}}"#)
    #expect(
        CommentSegment.split(parsed) == [
            .time("1:02:03", seconds: 3723), .text(" 和 12:75 和 2024:10:01 还有 "),
            .time("9:05", seconds: 545),
        ])
}

@Test(arguments: ["1:60:00", "01:99:02", "0:75:59", "00:00:60"])
func timestampsRejectInvalidClockComponents(_ text: String) {
    #expect(CommentSegment.split(text: text) == [.text(text)])
}

@Test func timestampsAcceptLongMinuteAndHourPositions() {
    #expect(CommentSegment.split(text: "75:59") == [.time("75:59", seconds: 4559)])
    #expect(CommentSegment.split(text: "1:59:59") == [.time("1:59:59", seconds: 7199)])
}
