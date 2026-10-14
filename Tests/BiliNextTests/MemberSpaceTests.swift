import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func spaceTabsUseTheirOwnIdentityAndOpenOnce() throws {
    #expect(MemberSpace.mid("space:546195") == 546195)
    #expect(MemberSpace.mid("space:0") == nil && MemberSpace.mid("BV1234567890") == nil)
    #expect(MemberSpace.mid("live:6") == nil && LiveSession.roomID("space:6") == nil)
    #expect(MemberSpace.tabID(7) == "space:7")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
        sessionStore: SessionStore(directory: directory), api: BilibiliAPI(restoreSession: false))
    model.openSpace(mid: 7, name: "UP", background: true)
    model.openSpace(mid: 7, name: "UP", background: true)
    model.openSpace(mid: 0, name: "无效", background: true)
    #expect(model.tabs.map(\.id) == ["space:7"])
    #expect(model.tabs[0].video.ownerID == 7 && model.tabs[0].video.title == "UP")
    // 小窗 has nothing to show for a space page.
    model.selected = "space:7"
    model.toggleMiniPlayer()
    #expect(!model.miniPlayer)
    model.clearTabs()
}

@MainActor
@Test func signedOutSpaceAsksForLoginInsteadOfRequestingSignedLists() {
    let space = MemberSpace(api: BilibiliAPI(restoreSession: false), mid: 7)
    space.isSignedIn = { false }
    space.setOrder("click")
    #expect(space.uploadsNeedLogin && !space.uploadsLoading && space.uploadsError == nil)
    space.order = "pubdate"
    space.keyword = "超市"
    space.search()
    #expect(space.uploadsNeedLogin && space.searched == "超市")
}
