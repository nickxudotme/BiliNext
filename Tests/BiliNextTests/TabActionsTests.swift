import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

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
@Test func miniPlayerRestoresSidebarAndPinningWithoutTouchingTabDetails() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.tabs = [
        SessionTab(video: Video(bvid: "BV1111111111", title: "一")),
        SessionTab(video: Video(bvid: "BV2222222222", title: "二")),
    ]
    let first = model.playbackInstance(for: model.tabs[0])
    let second = model.playbackInstance(for: model.tabs[1])
    second.theater = true
    model.selected = "BV1111111111"

    first.toggleMiniPlayer()
    #expect(model.miniPlayer && model.windowPinned && !model.sidebarPinned)
    // Switching tabs inside 小窗, then leaving, keeps each tab's own detail state.
    model.selected = "BV2222222222"
    model.toggleMiniPlayer()
    #expect(!model.miniPlayer && !model.windowPinned && model.sidebarPinned)
    #expect(!first.theater && second.theater)

    model.toggleWindowPin()
    model.toggleMiniPlayer()
    model.toggleMiniPlayer()
    #expect(model.windowPinned)
}

@MainActor
@Test func episodesCanBeFavoritedButNotLikedOrCoined() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.profile = UserProfile(id: 8, name: "离线测试")
    model.detail = VideoDetail(
        video: Video(bvid: "BV1111111111", title: "第 1 话", aid: 1, episodeID: 99), pages: [],
        description: "")
    model.requestFavorite()
    #expect(model.favoritePresented)
    model.requestCoin()
    #expect(!model.coinDialogPresented && !model.interactionBusy)
}

@MainActor
@Test func writesWaitForTheAccountStateBeforeToggling() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.profile = UserProfile(id: 8, name: "离线测试")
    model.detail = VideoDetail(
        video: Video(bvid: "BV1111111111", title: "一", aid: 1), pages: [], description: "")
    // A read is in flight for this video, so a like must not guess the current state.
    model.relationVideo = "BV1111111111"
    model.relationReading = true
    model.toggleLike()
    model.triple()
    #expect(!model.interactionBusy)
    #expect(model.toast == "正在读取互动状态，请稍候")
}

@MainActor
@Test func replacingATabKeepsItsPlaceInTheSidebar() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.tabs = [
        SessionTab(video: Video(bvid: "BV1111111111", title: "第一集")),
        SessionTab(video: Video(bvid: "BV2222222222", title: "别的")),
    ]
    model.unseenTabs = ["BV1111111111"]
    model.replace("BV1111111111", with: Video(bvid: "BV3333333333", title: "第二集"))
    #expect(model.tabs.map(\.id) == ["BV3333333333", "BV2222222222"])
    #expect(model.unseenTabs.isEmpty && model.selected == nil)
}

@MainActor
@Test func replacingInPlaceRemembersTheVideoForBack() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory)
    let model = AppModel(sessionStore: store, api: BilibiliAPI(restoreSession: false))
    model.tabs = [
        SessionTab(video: Video(bvid: "BV1111111111", title: "第一集"), cid: 1, position: 30)
    ]
    model.replace("BV1111111111", with: Video(bvid: "BV2222222222", title: "第二集"))
    model.replace("BV2222222222", with: Video(bvid: "BV3333333333", title: "第三集"))
    var trail = model.tabs[0].trail
    #expect(model.tabs.map(\.id) == ["BV3333333333"])
    #expect(trail.back.map(\.video.bvid) == ["BV1111111111", "BV2222222222"])
    #expect(trail.back.first?.position == 30 && trail.back.first?.cid == 1)
    // No tab is selected, so 后退 has no trail to step.
    #expect(!model.stepTabTrail(-1))

    // The history is part of the saved session, like a browser tab's.
    let restored = try store.read()
    #expect(restored[0].trail == trail)

    let current = model.tabs[0]
    let back = trail.step(-1, from: current)
    #expect(back?.video.bvid == "BV2222222222")
    #expect(trail.forward.map(\.video.bvid) == ["BV3333333333"])
    let previous = SessionTab(try #require(back), trail: trail)
    let forward = trail.step(1, from: previous)
    #expect(forward?.video.bvid == "BV3333333333")
    #expect(trail.back.map(\.video.bvid) == ["BV1111111111", "BV2222222222"])
    let past = trail.step(1, from: previous)
    #expect(past == nil)

    // Closing keeps the history with the tab, so ⇧⌘T brings it back.
    model.close("BV3333333333")
    model.undoClose()
    #expect(model.tabs.first?.trail.back.count == 2)
}

@Test func tabHistoryIsBoundedAndOldSessionsStillLoad() throws {
    var trail = TabTrail()
    for number in 0..<(TabTrail.limit + 5) {
        trail.leave(SessionTab(video: Video(bvid: "BV\(number)", title: "")))
    }
    #expect(trail.back.count == TabTrail.limit && trail.back.first?.video.bvid == "BV5")

    let legacy = Data(
        #"[{"video":{"bvid":"BV1111111111","title":"旧会话","author":"UP"},"cid":3,"position":12}]"#
            .utf8)
    let tabs = try JSONDecoder().decode([SessionTab].self, from: legacy)
    #expect(tabs[0].cid == 3 && tabs[0].position == 12 && tabs[0].trail == TabTrail())
}
