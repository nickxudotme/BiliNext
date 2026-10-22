import AppKit
import SwiftUI
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func commentReplyPreviewDoesNotReserveHiddenLines() throws {
    func row(_ text: String) -> BiliNextCore.Comment {
        let reply = BiliNextCore.Comment(
            id: 2, parentID: 1, rootID: 1, author: "回复者", avatar: nil, text: text,
            likes: 0, replyCount: 0, date: .distantPast, replies: [])
        return BiliNextCore.Comment(
            id: 1, parentID: 0, rootID: 0, author: "测试", avatar: nil,
            text: "当晚那种情况没发动政变就离谱这种事情放在我们这里上一个小时你不干下一个小时就去有告密的，他对手也居然让他踏踏实实的见到了第二天的太阳，只能说是一对绝妙的对手了",
            likes: 0, replyCount: 4, date: .distantPast,
            replies: [
                reply,
                BiliNextCore.Comment(
                    id: 3, parentID: 1, rootID: 1, author: "另一个", avatar: nil,
                    text: "只能说欧洲这方面经验和东方不太一样，贵族圈一般不会你死我活", likes: 1, replyCount: 0,
                    date: .distantPast, replies: []),
                BiliNextCore.Comment(
                    id: 4, parentID: 1, rootID: 1, author: "第三个", avatar: nil,
                    text: "我觉得这种毫无准备纯临时起意的事情肯定没多久政府就知道了，完全没有保密。" + text, likes: 0, replyCount: 0,
                    date: .distantPast, replies: []),
            ])
    }
    // The thread link is the final visible content. Its pink pixels must remain close
    // to the row bottom even when every preview has more than two lines of text.
    let renderer = ImageRenderer(
        content: CommentRow(
            comment: row(String(repeating: "回复内容", count: 100)), uploaderID: 0,
            openReply: { _ in }
        ) {}
        .frame(width: 457.5).background(.black).environment(\.colorScheme, .dark))
    renderer.scale = 1
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    var lastAccentRow: Int?
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            if color.redComponent > 0.6 && color.blueComponent > 0.2
                && color.redComponent > color.greenComponent * 1.5
            {
                lastAccentRow = y
            }
        }
    }
    let bottomGap = rep.pixelsHigh - 1 - (try #require(lastAccentRow))
    // 12pt row padding + 8pt preview padding + glyph descent/antialiasing.
    #expect(bottomGap <= 26)
}
