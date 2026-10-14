import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func nowPlayingDescribesTheSelectedVideoAndItsParts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(
        sessionStore: SessionStore(directory: directory), api: BilibiliAPI(restoreSession: false))
    #expect(NowPlaying.item(for: workspace) == nil)

    let video = Video(bvid: "BV1111111111", title: "第二集", author: "UP")
    let tab = SessionTab(video: video)
    workspace.tabs = [tab]
    workspace.selected = tab.id
    let page = workspace.playbackInstance(for: tab)
    // A tab whose media has not loaded yet has nothing to show.
    #expect(NowPlaying.item(for: workspace) == nil)

    page.detail = VideoDetail(
        video: video,
        pages: [
            VideoPage(cid: 1, number: 1, title: "上"), VideoPage(cid: 2, number: 2, title: "下"),
        ], description: "")
    page.pageID = 2
    page.duration = 120
    page.time = 30
    page.playbackRate = 1.5
    page.playing = true
    let item = try #require(NowPlaying.item(for: workspace))
    #expect(item.title == "第二集" && item.artist == "UP" && item.album == "P2 下")
    #expect(item.duration == 120 && item.elapsed == 30 && item.rate == 1.5 && item.playing)
    #expect(item.hasPreviousPage && !item.hasNextPage && !item.live)

    page.playing = false
    #expect(NowPlaying.item(for: workspace)?.rate == 0)
    workspace.clearTabs()
}
