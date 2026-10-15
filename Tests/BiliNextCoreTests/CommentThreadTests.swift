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

@Test func threadRowsKeepRailsAndAncestorsWhenIndentationStops() {
    let replies = [
        reply(7, parent: 4, "回复 @U4 :深层第一条"), reply(5, parent: 2),
        reply(4, parent: 3, "回复 @U3 :深层父亲"), reply(2, parent: 1),
        reply(3, parent: 2, "回复 @U2 :第二条"), reply(8, parent: 4), reply(6, parent: 1),
    ]
    let rows = CommentThread.rows(root: 1, replies: replies, maxDepth: 3)
    #expect(rows.map(\.id) == [2, 5, 3, 4, 7, 8, 6])
    #expect(rows.map(\.depth) == [1, 2, 2, 3, 3, 3, 1])
    #expect(rows.map(\.ancestors) == [[], [2], [2], [2, 3], [2, 3], [2, 3], []])
    #expect(
        rows.map(\.rails) == [
            [], [true], [false], [false, false], [false, true], [false, false], [],
        ])
    #expect(rows.map(\.descendants) == [5, 0, 3, 2, 0, 0, 0])
    #expect(rows[2].comment.text == "第二条" && rows[3].comment.text == "深层父亲")
    #expect(rows[4].comment.text == "回复 @U4 :深层第一条")

    let folded = CommentThread.rows(root: 1, replies: replies, collapsed: [4, 7], maxDepth: 3)
    #expect(folded.map(\.id) == [2, 5, 3, 4, 6])
    #expect(folded[3].collapsed && folded[3].descendants == 2)
    #expect(folded[3].ancestors == [2, 3] && folded[3].rails == [false, false])
}

@Test func threadRowsHandleDeepOutOfOrderRepliesAndKeepCollapsedTotals() {
    let count = 20_000
    let replies = (2..<(count + 2)).reversed().map {
        reply(Int64($0), parent: Int64($0 - 1))
    }
    let rows = CommentThread.rows(root: 1, replies: replies)
    #expect(rows.count == count)
    #expect(
        rows.enumerated().allSatisfy { index, row in
            row.id == Int64(index + 2) && row.depth == min(index + 1, 6)
                && row.descendants == count - index - 1
        })
    #expect(rows.last?.ancestors == [2, 3, 4, 5, 6])
    #expect(rows.last?.rails == Array(repeating: false, count: 5))

    let folded = CommentThread.rows(root: 1, replies: replies, collapsed: [2])
    #expect(folded.count == 1 && folded[0].collapsed && folded[0].descendants == count - 1)
}
