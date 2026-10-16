import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
private func favoriteWorkspace(
    loader: @escaping (BrowsePageRequest) async throws -> BrowsePageResult
) -> AppModel {
    let model = AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        api: BilibiliAPI(restoreSession: false), browsePageLoader: loader)
    model.profile = UserProfile(id: 8, name: "离线测试")
    return model
}

@MainActor
private final class FavoritePageGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Test func favoriteRenamePreservesMountedContentsAndPagination() async throws {
    let initial = [FavoriteFolder(id: 42, title: "原名", count: 12)]
    var calls = 0
    let model = favoriteWorkspace { _ in
        calls += 1
        return BrowsePageResult(
            videos: [Video(bvid: "BV1111111111", title: "保留")], next: nil,
            folders: initial, folderID: 42)
    }
    model.navigate(.favorites)
    let page = try #require(model.loadedBrowseInstance(for: .favorites))
    await page.browseTask?.value
    page.libraryQuery = "关键词"
    let revision = page.browseRevision
    model.favoriteFoldersDidChange(
        [FavoriteFolder(id: 42, title: "新名", count: 12)], accountID: 8)
    #expect(model.loadedBrowseInstance(for: .favorites) === page)
    #expect(page.folders.first?.title == "新名")
    #expect(page.videos.first?.title == "保留" && page.libraryQuery == "关键词")
    #expect(page.browseRevision == revision && calls == 1)
}

@MainActor
@Test func unchangedFolderListLeavesALoadingFavoritesPageAlone() async throws {
    let initial = [FavoriteFolder(id: 42, title: "默认", count: 3)]
    let gate = FavoritePageGate()
    var calls = 0
    let model = favoriteWorkspace { _ in
        calls += 1
        if calls == 2 { await gate.suspend() }
        return BrowsePageResult(
            videos: [Video(bvid: "BV1111111111", title: "第 \(calls) 次")], next: nil,
            folders: initial, folderID: 42)
    }
    model.navigate(.favorites)
    let page = try #require(model.loadedBrowseInstance(for: .favorites))
    await page.browseTask?.value
    model.favoriteFoldersDidChange(initial, accountID: 8)
    page.refresh()
    for _ in 0..<100 where !gate.started { try await Task.sleep(for: .milliseconds(5)) }
    #expect(page.loading)
    // The picker's read finds the same folders: the in-flight load keeps going.
    model.favoriteFoldersDidChange(initial, accountID: 8)
    #expect(page.loading && page.browseTask != nil)
    gate.release()
    await page.browseTask?.value
    #expect(page.videos.first?.title == "第 2 次" && calls == 2)
}

@MainActor
@Test(arguments: [true, false])
func favoriteDeletionReusesAnotherFolderAndRepairsHistory(explicitDeletion: Bool) async throws {
    let initial = [
        FavoriteFolder(id: 42, title: "保留", count: 2),
        FavoriteFolder(id: 43, title: "删除", count: 1),
    ]
    var calls = 0
    let model = favoriteWorkspace { request in
        calls += 1
        return BrowsePageResult(
            videos: [Video(bvid: "folder\(request.folderID)", title: "内容")], next: nil,
            folders: initial, folderID: request.folderID == 0 ? 42 : request.folderID)
    }
    model.selectFavoriteFolder(42)
    let kept = try #require(model.loadedBrowseInstance(for: .favorites))
    await kept.browseTask?.value
    model.selectFavoriteFolder(43)
    let removed = try #require(model.loadedBrowseInstance(for: .favorites))
    await removed.browseTask?.value
    model.cachedLists["收藏:43::mtime"] = removed.videos
    model.favoriteFoldersDidChange(
        [initial[0]], accountID: 8, deletedFolderID: explicitDeletion ? 43 : nil)
    #expect(model.folderID == 42 && model.loadedBrowseInstance(for: .favorites) === kept)
    #expect(!model.browseInstances.values.contains { $0 === removed })
    #expect(!model.history.contains("收藏:43"))
    #expect(model.cachedLists["收藏:43::mtime"] == nil && calls == 2)
    #expect(removed.videos.isEmpty)
}

@MainActor
@Test func favoriteFirstFolderMakesTheEmptyLibraryLoadable() async throws {
    var available: [FavoriteFolder] = []
    let model = favoriteWorkspace { _ in
        BrowsePageResult(
            videos: [], next: nil, folders: available, folderID: available.first?.id ?? 0)
    }
    model.navigate(.favorites)
    let original = try #require(model.loadedBrowseInstance(for: .favorites))
    await original.browseTask?.value
    available = [FavoriteFolder(id: 42, title: "新收藏夹", count: 0)]
    model.favoriteFoldersDidChange(available, accountID: 8, preferredFolderID: 42)
    let page = try #require(model.loadedBrowseInstance(for: .favorites))
    await page.browseTask?.value
    #expect(page === original && page.folderID == 42 && page.browseLoadAttempted)
    #expect(page.folders.first?.id == 42)
}

@MainActor
@Test func favoriteSelectingANewFolderRecordsItsNavigationRoute() async throws {
    var available = [FavoriteFolder(id: 42, title: "已有收藏夹", count: 0)]
    let model = favoriteWorkspace { request in
        BrowsePageResult(
            videos: [], next: nil, folders: available,
            folderID: request.folderID == 0 ? 42 : request.folderID)
    }
    model.selectFavoriteFolder(42)
    await model.loadedBrowseInstance(for: .favorites)?.browseTask?.value
    available.append(FavoriteFolder(id: 43, title: "新收藏夹", count: 0))
    model.favoriteFoldersDidChange(available, accountID: 8, preferredFolderID: 43)
    #expect(model.history.last == "收藏:43" && model.folderID == 43)
    await model.loadedBrowseInstance(for: .favorites)?.browseTask?.value
    model.moveHistory(-1)
    #expect(model.folderID == 42)
}

@MainActor
@Test func favoriteMembershipSynchronizesVideoStateAndInvalidatesOnlyChangedFolders() async throws {
    let folders = [
        FavoriteFolder(id: 42, title: "改变", count: 2),
        FavoriteFolder(id: 43, title: "保留", count: 5),
    ]
    let model = favoriteWorkspace { request in
        BrowsePageResult(
            videos: [Video(bvid: "folder\(request.folderID)", title: "内容")], next: nil,
            folders: folders, folderID: request.folderID)
    }
    model.selectFavoriteFolder(42)
    let changed = try #require(model.loadedBrowseInstance(for: .favorites))
    await changed.browseTask?.value
    model.selectFavoriteFolder(43)
    let untouched = try #require(model.loadedBrowseInstance(for: .favorites))
    await untouched.browseTask?.value
    let video = Video(bvid: "BV1111111111", title: "视频", aid: 99)
    let tab = SessionTab(video: video)
    model.tabs = [tab]
    let player = model.playbackInstance(for: tab)
    player.detail = VideoDetail(
        video: video, pages: [], description: "", stats: VideoStats(favorites: 20))
    player.relationReading = true
    let generation = player.relationGeneration
    model.selected = tab.id
    player.favoriteMembershipDidChange(aid: 99, before: [], after: [42], accountID: 8)
    #expect(player.relation.favorited && !player.relationReading)
    #expect(player.relationGeneration != generation && player.detail?.stats.favorites == 21)
    #expect(changed.videos.isEmpty && !changed.browseLoadAttempted)
    #expect(untouched.videos.count == 1 && untouched.browseLoadAttempted)
    #expect(untouched.folders.map(\.count) == [3, 5])
    player.favoriteMembershipDidChange(aid: 99, before: [42], after: [43], accountID: 8)
    #expect(player.detail?.stats.favorites == 21 && player.relation.favorited)
    #expect(untouched.folders.map(\.count) == [2, 6])
}

@MainActor
@Test func favoriteUpdatesFromAnOldAccountAreDiscarded() {
    let model = favoriteWorkspace { _ in BrowsePageResult(videos: [], next: nil) }
    model.folders = [FavoriteFolder(id: 42, title: "当前账号", count: 2)]
    model.favoriteFoldersDidChange([], accountID: 7, deletedFolderID: 42)
    model.favoriteMembershipDidChange(aid: 99, before: [42], after: [], accountID: 7)
    #expect(model.folders.first?.title == "当前账号" && model.folders.first?.count == 2)
}

@MainActor
@Test func favoriteDeletionRejectsALatePageResponse() async throws {
    let gate = FavoritePageGate()
    let kept = FavoriteFolder(id: 42, title: "保留", count: 0)
    let removed = FavoriteFolder(id: 43, title: "删除", count: 1)
    let model = favoriteWorkspace { request in
        if request.folderID == 43 { await gate.suspend() }
        return BrowsePageResult(
            videos: [Video(bvid: "late", title: "迟到内容")], next: nil,
            folders: [kept, removed], folderID: request.folderID)
    }
    model.selectFavoriteFolder(43)
    let page = try #require(model.loadedBrowseInstance(for: .favorites))
    let task = try #require(page.browseTask)
    while !gate.started { await Task.yield() }
    model.favoriteFoldersDidChange([kept], accountID: 8, deletedFolderID: 43)
    gate.release()
    await task.value
    #expect(page.videos.isEmpty && page.folders.isEmpty && !page.loading)
    #expect(!model.browseInstances.values.contains { $0 === page })
    #expect(model.folderID == 42)
    await model.loadedBrowseInstance(for: .favorites)?.browseTask?.value
}
