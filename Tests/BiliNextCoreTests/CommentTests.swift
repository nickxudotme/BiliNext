import Testing

@testable import BiliNextCore

private func reply(_ id: Int64, parent: Int64 = 1) -> BiliNextCore.Comment {
    BiliNextCore.Comment.parse([
        "rpid": id, "root": Int64(1), "parent": parent, "content": ["message": "reply"],
        "member": ["uname": "user"],
    ])!
}

@Test func replyTreeUsesParentsInsteadOfArrayOrder() {
    let tree = CommentBranch.forest(
        [reply(4, parent: 3), reply(2), reply(3, parent: 2), reply(2)], rootID: 1)
    #expect(tree.map(\.id) == [2])
    #expect(tree.first?.children.first?.id == 3)
    #expect(tree.first?.children.first?.children.first?.id == 4)
    #expect(tree.first?.descendantCount == 2)
    #expect(tree.first?.comment.rootID == 1)
}

@Test func orphanRepliesRemainVisibleAndReattachAfterPagination() {
    let orphan = reply(3, parent: 2)
    #expect(CommentBranch.forest([orphan], rootID: 1).map(\.id) == [3])
    let tree = CommentBranch.forest([orphan, reply(2)], rootID: 1)
    #expect(tree.map(\.id) == [2])
    #expect(tree.first?.children.map(\.id) == [3])
}

@Test func corruptReplyCyclesDoNotLoseCommentsOrRecurseForever() {
    let tree = CommentBranch.forest(
        [reply(2, parent: 3), reply(3, parent: 2), reply(4, parent: 4), reply(1)], rootID: 1)
    #expect(tree.map(\.id) == [2, 3, 4])
    #expect(tree.allSatisfy { $0.children.isEmpty })
}
