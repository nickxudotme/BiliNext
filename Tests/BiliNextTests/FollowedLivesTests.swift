import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func dynamicSectionsShareFollowedLiveState() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(
        sessionStore: SessionStore(directory: directory),
        api: BilibiliAPI(restoreSession: false))
    defer { workspace.stopMedia() }
    workspace.dynamicMode = "视频"
    let videos = workspace.browseInstance(for: .dynamic)
    workspace.dynamicMode = "全部"
    let all = workspace.browseInstance(for: .dynamic)
    #expect(videos !== all)
    #expect(videos.followedLives === all.followedLives)
    #expect(videos.followedLives === workspace.followedLives)
}

@MainActor
@Test func dynamicLiveRefreshUpdatesBothSectionsAndAccountChangeRejectsOldResponse() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(
        sessionStore: SessionStore(directory: directory),
        api: BilibiliAPI(restoreSession: false))
    defer { workspace.stopMedia() }
    var calls = 0
    var response: CheckedContinuation<[LiveRoom], Never>?
    let lives = FollowedLives(load: {
        calls += 1
        if calls == 2 { return await withCheckedContinuation { response = $0 } }
        return [LiveRoom(id: Int64(calls), title: "直播", isLive: true)]
    })
    workspace.ownedFollowedLives = lives
    workspace.dynamicMode = "视频"
    let videos = workspace.browseInstance(for: .dynamic)
    workspace.dynamicMode = "全部"
    let all = workspace.browseInstance(for: .dynamic)
    videos.followedLives.refresh()
    await lives.task?.value
    #expect(videos.followedLives.rooms.map(\.id) == [1])
    #expect(all.followedLives.rooms == videos.followedLives.rooms)
    all.followedLives.refresh()
    let pending = lives.task
    for _ in 0..<100 where response == nil { await Task.yield() }
    #expect(response != nil && videos.followedLives.loading)
    workspace.accountGeneration = UUID()
    #expect(videos.followedLives.rooms.isEmpty && all.followedLives.rooms.isEmpty)
    #expect(!lives.loading && lives.error == nil)
    videos.followedLives.refresh()
    await lives.task?.value
    response?.resume(returning: [LiveRoom(id: 2, title: "旧账号", isLive: true)])
    await pending?.value
    #expect(videos.followedLives.rooms.map(\.id) == [3])
    #expect(all.followedLives.rooms == videos.followedLives.rooms)
    #expect(!lives.loading)
}
