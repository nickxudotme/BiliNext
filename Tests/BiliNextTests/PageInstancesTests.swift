import AVFoundation
import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_DASH_TEST"] == "1"))
func playbackTabSwitchRetainsLoadedMedia() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let first = SessionTab(video: Video(bvid: "BV1p1n8zdEAk", title: "4K 风景"))
    let second = SessionTab(video: Video(bvid: "BV1dyaZ6gEwU", title: "科普视频"))
    workspace.tabs = [first, second]
    let a = workspace.playbackInstance(for: first)
    let b = workspace.playbackInstance(for: second)
    a.player.isMuted = true
    b.player.isMuted = true
    defer {
        workspace.selected = nil
        workspace.clearTabs()
    }
    func waitForPlayback(_ page: AppModel) async throws {
        for _ in 0..<200 {
            if page.playerError != nil || page.player.currentTime().seconds > 1 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(page.playerError == nil)
        #expect(page.player.currentItem?.status == .readyToPlay)
        #expect(page.player.currentTime().seconds > 1)
    }
    workspace.activate(first.id, autoplay: true)
    try await waitForPlayback(a)
    let item = try #require(a.player.currentItem)
    a.setRate(1.5)
    a.seek(30)
    try await Task.sleep(for: .seconds(1))
    workspace.activate(second.id, autoplay: true)
    let position = a.player.currentTime().seconds
    try await waitForPlayback(b)
    #expect(a.player.rate == 0)
    #expect(a.player.currentItem === item)
    #expect(abs(a.player.currentTime().seconds - position) < 0.5)
    workspace.activate(first.id, autoplay: true)
    #expect(a.player.currentItem === item)
    #expect(a.playbackRate == 1.5)
    #expect(b.player.rate == 0)
    #expect(workspace.playbackInstances.count == 2)
    workspace.close(second.id)
    #expect(workspace.playbackInstances.count == 1)
    #expect(a.player.currentItem === item)
    print(
        "Persistent tabs: two muted players, same loaded item and position retained, inactive page paused, close released only its player"
    )
}

@MainActor
@Test func browsingPagesKeepIndependentStateWhenRevisited() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let home = workspace.browseInstance(for: "首页")
    let dynamic = workspace.browseInstance(for: "动态")
    let search = workspace.browseInstance(for: "搜索")
    home.homeSection = "热门"
    home.videos = [Video(bvid: "BV1111111111", title: "保留的内容")]
    dynamic.dynamicMode = "全部"
    search.query = "4K 风景"
    workspace.navigate("首页")
    workspace.navigate("动态")
    workspace.moveHistory(-1)
    #expect(workspace.menu == "首页")
    #expect(workspace.browseInstance(for: "首页") === home)
    #expect(home.homeSection == "热门" && home.videos.count == 1)
    #expect(dynamic.dynamicMode == "全部")
    #expect(search.query == "4K 风景")
    search.toast = "页面消息"
    #expect(workspace.toast == "页面消息")
    search.loginPresented = true
    #expect(workspace.loginPresented)
}

@MainActor
@Test func playbackPagesKeepPlayersAndReleaseClosedTabs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let first = SessionTab(video: Video(bvid: "BV1111111111", title: "一"))
    let second = SessionTab(video: Video(bvid: "BV2222222222", title: "二"))
    workspace.tabs = [first, second]
    let a = workspace.playbackInstance(for: first)
    let b = workspace.playbackInstance(for: second)
    #expect(a.player !== b.player)
    #expect(a.danmaku !== b.danmaku)
    #expect(a.playbackClock !== b.playbackClock)
    a.qualityID = 120
    a.playbackRate = 1.5
    a.theater = true
    a.pageID = 42
    a.officialCore = true
    a.time = 123
    b.pageID = 43
    b.officialCore = true
    b.time = 456
    workspace.saveSession()
    let saved = try SessionStore(directory: directory).read()
    #expect(saved[0].position == 123 && saved[0].cid == 42)
    #expect(saved[1].position == 456 && saved[1].cid == 43)
    #expect(workspace.playbackInstance(for: first) === a)
    #expect(a.qualityID == 120 && a.playbackRate == 1.5 && a.theater)
    workspace.close(second.id)
    #expect(workspace.playbackInstances[second.id] == nil)
    #expect(workspace.playbackInstances[first.id] === a)
    workspace.undoClose()
    #expect(workspace.tabs.count == 2)
    #expect(workspace.playbackInstances[second.id] == nil)
    workspace.clearTabs()
    #expect(workspace.playbackInstances.isEmpty)
}
