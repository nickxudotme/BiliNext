import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func liveTabsUseSeparateRoomIdentity() {
    #expect(LiveSession.roomID("live:6") == 6)
    #expect(LiveSession.roomID("live:0") == nil)
    #expect(LiveSession.roomID("BV1234567890") == nil)
}

@MainActor
@Test func liveTabsRestoreActivateSuspendCloseAndUndoOffline() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory)
    try store.write([
        SessionTab(video: Video(bvid: "live:6", title: "赛事", author: "主播")),
        SessionTab(video: Video(bvid: "live:42", title: "第二个直播间")),
    ])
    let api = BilibiliAPI(restoreSession: false)
    let model = AppModel(sessionStore: store, api: api)
    #expect(model.tabs.map(\.id) == ["live:6", "live:42"])
    // Retained, idle sessions exercise tab lifecycle without reload or an API request.
    let first = model.playbackInstance(for: model.tabs[0])
    let second = model.playbackInstance(for: model.tabs[1])
    let firstSession = LiveSession(api: api, roomID: 6)
    let secondSession = LiveSession(api: api, roomID: 42)
    first.liveSession = firstSession
    second.liveSession = secondSession
    model.activate("live:6", autoplay: true)
    #expect(model.selected == "live:6" && first.playbackTabActive)
    #expect(first.liveSession === firstSession && first.videoTask == nil)
    model.activate("live:42", autoplay: true)
    #expect(!first.playbackTabActive && !firstSession.playing)
    #expect(model.selected == "live:42" && second.playbackTabActive)
    #expect(second.liveSession === secondSession && second.videoTask == nil)
    model.close("live:42")
    #expect(model.playbackInstances["live:42"] == nil)
    #expect(second.liveSession == nil && secondSession.player == nil)
    #expect(model.selected == "live:6" && first.liveSession === firstSession)
    #expect(try store.read().map(\.id) == ["live:6"])
    model.undoClose()
    #expect(model.tabs.map(\.id) == ["live:6", "live:42"])
    #expect(model.playbackInstances["live:42"] == nil)
    #expect(try store.read().map(\.id) == ["live:6", "live:42"])
    model.suspendPlaybackTabs()
    #expect(!first.playbackTabActive && !firstSession.playing)
    model.releasePlaybackTab("live:6")
    #expect(first.liveSession == nil && model.playbackInstances.isEmpty)
}
