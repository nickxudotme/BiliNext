import Foundation
import Testing

@testable import BiliNextCore

private func reply(_ id: Int64, parent: Int64, _ text: String = "内容") -> BiliNextCore.Comment {
    BiliNextCore.Comment(
        id: id, parentID: parent, rootID: 1, author: "U\(id)", avatar: nil, text: text, likes: 0,
        replyCount: 0, date: Date(timeIntervalSince1970: 0), replies: [])
}

@Test func threadRowsNestRepliesUnderTheirParents() {
    let replies = [
        reply(2, parent: 1, "第一"),
        reply(3, parent: 2, "回复 @U2 :同意"),
        reply(4, parent: 3, "回复 @U3：不同意"),
        reply(5, parent: 1, "第二"),
        reply(6, parent: 99, "回复 @别人 :父评论未加载"),
    ]
    let rows = CommentThread.rows(root: 1, replies: replies)
    #expect(rows.map(\.id) == [2, 3, 4, 5, 6])
    #expect(rows.map(\.depth) == [1, 2, 3, 1, 1])
    #expect(rows[1].comment.text == "同意" && rows[2].comment.text == "不同意")
    #expect(rows[4].comment.text == "回复 @别人 :父评论未加载")
    #expect(rows[2].ancestors == [2, 3] && rows[0].descendants == 2)
    // 3 is 2's only reply and 4 is 3's, so no line runs past them.
    #expect(rows[1].rails == [false] && rows[2].rails == [false, false])

    let folded = CommentThread.rows(root: 1, replies: replies, collapsed: [2])
    #expect(folded.map(\.id) == [2, 5, 6] && folded[0].collapsed && folded[0].descendants == 2)

    // Past the depth limit replies stop indenting and keep their prefix.
    let deep = CommentThread.rows(root: 1, replies: replies, maxDepth: 2)
    #expect(deep.map { $0.depth } == [1, 2, 2, 1, 1])
    #expect(deep[2].comment.text == "回复 @U3：不同意")
}
