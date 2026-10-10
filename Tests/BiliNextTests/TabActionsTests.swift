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
