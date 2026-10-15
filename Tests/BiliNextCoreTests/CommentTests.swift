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

@Test func replyTreeKeepsInputSiblingOrderAndFirstCopies() {
    let tree = CommentBranch.forest(
        [
            reply(5, parent: 2), reply(4), reply(3, parent: 2), reply(2),
            reply(6, parent: 3), reply(5, parent: 99),
        ], rootID: 1)
    #expect(tree.map(\.id) == [4, 2])
    #expect(tree[1].children.map(\.id) == [5, 3])
    #expect(tree[1].children[1].children.map(\.id) == [6])
    #expect(tree[1].descendantCount == 3)
}

@Test func repliesLeadingIntoCyclesStayVisibleWhileOrphanBranchesReattach() {
    let replies = [
        reply(7, parent: 6), reply(2, parent: 3), reply(3, parent: 2),
        reply(4, parent: 2), reply(5, parent: 4), reply(6, parent: 99), reply(1),
    ]
    let tree = CommentBranch.forest(replies, rootID: 1)
    #expect(tree.map(\.id) == [2, 3, 4, 5, 6])
    #expect(tree.prefix(4).allSatisfy { $0.children.isEmpty && $0.descendantCount == 0 })
    #expect(tree.last?.children.map(\.id) == [7])
    #expect(tree.last?.descendantCount == 1)

    let paged = CommentBranch.forest(replies + [reply(99)], rootID: 1)
    #expect(paged.map(\.id) == [2, 3, 4, 5, 99])
    #expect(paged.last?.children.first?.id == 6)
    #expect(paged.last?.children.first?.children.first?.id == 7)
    #expect(paged.last?.descendantCount == 2)
}

@Test func replyTreeBuildsAndReleasesAVeryDeepBranchWithoutRecursiveStorage() {
    let count = 50_000
    let replies = (2..<(count + 2)).reversed().map { reply(Int64($0), parent: Int64($0 - 1)) }
    let tree = CommentBranch.forest(replies, rootID: 1)
    #expect(tree.count == 1 && tree.first?.descendantCount == count - 1)
    var current = tree.first
    var visited = 0
    var correct = true
    while let branch = current {
        correct =
            correct && branch.id == Int64(visited + 2)
            && branch.descendantCount == count - visited - 1
        visited += 1
        current = branch.children.first
    }
    #expect(visited == count && correct)
}

@Test func replyTreeResolvesALongCycleWithoutLosingReplies() {
    let count = 20_000
    let replies = (2..<(count + 2)).map {
        reply(Int64($0), parent: $0 == count + 1 ? 2 : Int64($0 + 1))
    }
    let tree = CommentBranch.forest(replies, rootID: 1)
    #expect(tree.map(\.id) == replies.map(\.id))
    #expect(tree.allSatisfy { $0.children.isEmpty && $0.descendantCount == 0 })
}
