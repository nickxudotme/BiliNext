import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func clearingOtherTabsPreservesCurrentVideoAndUndo() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory)
    let model = AppModel(sessionStore: store)
    model.tabs = [
        SessionTab(video: Video(bvid: "BV1111111111", title: "前一个")),
        SessionTab(video: Video(bvid: "BV2222222222", title: "当前"), cid: 42, position: 123),
        SessionTab(video: Video(bvid: "BV3333333333", title: "后一个")),
    ]
    model.selected = "BV2222222222"
    model.clearTabs()
    #expect(model.selected == "BV2222222222")
    #expect(model.tabs.map(\.id) == ["BV2222222222"])
    #expect(model.tabs[0].cid == 42 && model.tabs[0].position == 123)
    #expect(model.closed.map(\.id) == ["BV1111111111", "BV3333333333"])
    #expect(try store.read().map(\.id) == ["BV2222222222"])
    model.undoClose()
    #expect(model.tabs.count == 3)
    #expect(model.selected == "BV2222222222")
    #expect(model.closed.isEmpty)
}

@MainActor
@Test func closingOtherOrLowerTabsIsUndoableAndClearsUnseenMarks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.open(Video(bvid: "BV1111111111", title: "一"), background: true)
    model.open(Video(bvid: "BV2222222222", title: "二"), background: true)
    model.open(Video(bvid: "BV3333333333", title: "三"), background: true)
    #expect(model.unseenTabs.count == 3)

    model.closeOtherTabs(keeping: "BV2222222222", onlyBelow: true)
    #expect(model.tabs.map(\.id) == ["BV1111111111", "BV2222222222"])
    #expect(model.closed.map(\.id) == ["BV3333333333"])
    #expect(!model.unseenTabs.contains("BV3333333333"))

    model.closeOtherTabs(keeping: "BV2222222222")
    #expect(model.tabs.map(\.id) == ["BV2222222222"])
    #expect(model.closed.map(\.id) == ["BV1111111111"])
    model.undoClose()
    #expect(model.tabs.map(\.id) == ["BV2222222222", "BV1111111111"])
}

@Test func tabCyclingWrapsAndStartsFromTheEnds() {
    #expect(AppModel.tabIndex(after: nil, count: 3, delta: 1) == 0)
    #expect(AppModel.tabIndex(after: nil, count: 3, delta: -1) == 2)
    #expect(AppModel.tabIndex(after: 2, count: 3, delta: 1) == 0)
    #expect(AppModel.tabIndex(after: 0, count: 3, delta: -1) == 2)
    #expect(AppModel.tabIndex(after: 1, count: 3, delta: 1) == 2)
}

@MainActor
@Test func anonymousInteractionsAskToLogInWithoutWriting() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.detail = VideoDetail(
        video: Video(bvid: "BV1111111111", title: "一", aid: 1), pages: [], description: "")
    model.triple()
    #expect(model.loginPresented)
    #expect(!model.interactionBusy)
    model.loginPresented = false
    model.requestCoin()
    #expect(model.loginPresented && !model.coinDialogPresented)
}

@MainActor
@Test func miniPlayerRestoresSidebarDetailsAndPinning() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.tabs = [SessionTab(video: Video(bvid: "BV1111111111", title: "一"))]
    let page = model.playbackInstance(for: model.tabs[0])
    model.selected = "BV1111111111"

    page.toggleMiniPlayer()
    #expect(model.miniPlayer && model.windowPinned && !model.sidebarPinned && page.theater)

    model.toggleMiniPlayer()
    #expect(!model.miniPlayer && !model.windowPinned && model.sidebarPinned && !page.theater)

    model.toggleWindowPin()
    model.toggleMiniPlayer()
    model.toggleMiniPlayer()
    #expect(model.windowPinned)
}
