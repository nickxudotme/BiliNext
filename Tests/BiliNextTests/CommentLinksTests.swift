import Foundation
import Testing

@testable import BiliNext

@Test(arguments: ["普通关键词", "AC/DC", "/开头//结尾/", "A/B % + ? # 中文"])
func commentSearchLinksPreserveTheWholeKeyword(_ keyword: String) {
    let url = CommentLinks.search(keyword)
    #expect(CommentLinks.value(in: url) == keyword)
}

@Test func commentPlayerLinksKeepTheirTargets() {
    #expect(CommentLinks.value(in: CommentLinks.video("BV1xx411c7mD")) == "BV1xx411c7mD")
    #expect(CommentLinks.value(in: CommentLinks.seek(123)) == "123")
}
