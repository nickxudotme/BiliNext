import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
private final class PersistentBrowseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        await withCheckedContinuation {
            continuation = $0
            entered = true
            entry?.resume()
            entry = nil
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func persistentWorkspace(
    profileLoader: (() async throws -> UserProfile)? = nil,
    loader: @escaping (BrowsePageRequest) async throws -> BrowsePageResult
) -> AppModel {
    AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        api: BilibiliAPI(restoreSession: false), browsePageLoader: loader,
        profileLoader: profileLoader)
}

private func persistentPage(_ request: BrowsePageRequest) -> BrowsePageResult {
    BrowsePageResult(
        videos: [
            Video(
                bvid:
                    "\(request.destination)-\(request.homeSection)-\(request.folderID)-\(request.page)",
                title: "\(request.homeSection)第\(request.page)页")
        ], next: request.usesCursor ? "cursor-\(request.page)" : String(request.page + 1))
}

@MainActor
@Test func persistentBrowseIdentityQueriesHaveNoCreationOrLoadingSideEffects() {
    var calls = 0
    let workspace = persistentWorkspace { request in
        calls += 1
        return persistentPage(request)
    }
    #expect(workspace.browsePageID(for: "首页") == "首页:推荐")
    #expect(workspace.browsePageID(for: "动态") == "动态:视频")
    #expect(workspace.browsePageID(for: "收藏") == "收藏:0")
    #expect(workspace.loadedBrowseInstance(for: "首页") == nil)
    #expect(workspace.browseInstances.isEmpty && calls == 0)
}

@MainActor
@Test func persistentBrowseRecommendedAndPopularKeepIndependentLoadedPages() async throws {
    var requests: [String] = []
    let workspace = persistentWorkspace { request in
        requests.append("\(request.homeSection):\(request.page)")
        return persistentPage(request)
    }
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let recommended = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await recommended.browseTask?.value
    let originalVideos = recommended.videos.map(\.id)
    let originalOffset = recommended.offset
    workspace.selectBrowseSection(destination: "首页", section: "热门")
    let popular = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await popular.browseTask?.value
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    #expect(workspace.loadedBrowseInstance(for: "首页") === recommended)
    #expect(recommended !== popular && workspace.browseInstances.count == 2)
    #expect(recommended.videos.map(\.id) == originalVideos && recommended.page == 3)
    #expect(recommended.offset == originalOffset && recommended.hasMore)
    #expect(recommended.browseRevision == 1 && popular.browseRevision == 1)
    #expect(!recommended.playbackTabActive && !popular.playbackTabActive)
    #expect(requests == ["推荐:1", "推荐:2", "推荐:3", "热门:1", "热门:2", "热门:3"])
    let count = workspace.history.count
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    #expect(workspace.history.count == count && requests.count == 6)
}

@MainActor
@Test func persistentBrowseFirstChildSelectionNeverLoadsTheDefaultSection() async throws {
    var sections: [String] = []
    let workspace = persistentWorkspace { request in
        sections.append(request.homeSection)
        return persistentPage(request)
    }
    workspace.selectBrowseSection(destination: "首页", section: "热门")
    let page = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await page.browseTask?.value
    #expect(sections == ["热门", "热门", "热门"])
    #expect(workspace.browseInstances["首页:推荐"] == nil)
    #expect(workspace.browseInstances["首页:热门"] === page && page.browseRevision == 1)
}

@MainActor
@Test func persistentBrowseDynamicVideoAndAllKeepSeparateIdentityAndRefreshCounters() async throws {
    var calls = 0
    let workspace = persistentWorkspace { request in
        calls += 1
        return persistentPage(request)
    }
    workspace.profile = UserProfile(id: 8, name: "离线测试")
    workspace.selectBrowseSection(destination: "动态", section: "视频")
    let video = try #require(workspace.loadedBrowseInstance(for: "动态"))
    await video.browseTask?.value
    workspace.selectBrowseSection(destination: "动态", section: "全部")
    let all = try #require(workspace.loadedBrowseInstance(for: "动态"))
    #expect(video !== all && all.dynamicMode == "全部" && all.timelineRefresh == 1)
    workspace.selectBrowseSection(destination: "动态", section: "视频")
    workspace.selectBrowseSection(destination: "动态", section: "全部")
    #expect(calls == 3 && video.browseRevision == 1 && all.timelineRefresh == 1)
    #expect(workspace.browseInstances.count == 2)
}

@MainActor
@Test func persistentBrowseDefaultFavoriteAliasUsesOneMountedInstanceAndPreservesFolderPages()
    async throws
{
    var requests: [Int64] = []
    let folders = [
        FavoriteFolder(id: 42, title: "默认收藏", count: 50),
        FavoriteFolder(id: 43, title: "另一个", count: 50),
    ]
    let workspace = persistentWorkspace { request in
        requests.append(request.folderID)
        return BrowsePageResult(
            videos: persistentPage(request).videos, next: String(request.page + 1),
            folders: request.reloadFolders ? folders : nil,
            folderID: request.folderID == 0 ? 42 : request.folderID)
    }
    workspace.profile = UserProfile(id: 8, name: "离线测试")
    workspace.navigate("收藏")
    let original = try #require(workspace.loadedBrowseInstance(for: "收藏"))
    await original.browseTask?.value
    #expect(original.folderID == 42 && original.page == 3 && requests == [0, 42, 42])
    workspace.selectFavoriteFolder(42)
    #expect(workspace.loadedBrowseInstance(for: "收藏") === original)
    #expect(workspace.browsePageID(for: "收藏") == "收藏:0")
    #expect(workspace.browseInstances.values.filter { $0 === original }.count == 1)
    workspace.selectFavoriteFolder(43)
    let other = try #require(workspace.loadedBrowseInstance(for: "收藏"))
    #expect(other.folders.map(\.id) == [42, 43])  // Sidebar metadata is immediately available.
    await other.browseTask?.value
    workspace.selectFavoriteFolder(42)
    #expect(workspace.loadedBrowseInstance(for: "收藏") === original && other !== original)
    #expect(requests == [0, 42, 42, 43, 43, 43] && workspace.browseInstances.count == 2)
    #expect(original.browseRevision == 1 && other.browseRevision == 1)
    workspace.moveHistory(-1)
    workspace.moveHistory(-1)
    #expect(workspace.folderID == 0 && workspace.loadedBrowseInstance(for: "收藏") === original)
    #expect(requests.count == 6)
}

@MainActor
@Test func persistentBrowseHistoryRestoresChildRoutesAndVideoBackReturnsCurrentBrowseFirst()
    async throws
{
    var requests = 0
    let workspace = persistentWorkspace { request in
        requests += 1
        return persistentPage(request)
    }
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let recommended = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await recommended.browseTask?.value
    workspace.selectBrowseSection(destination: "首页", section: "热门")
    let popular = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await popular.browseTask?.value
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    workspace.moveHistory(-1)
    #expect(workspace.homeSection == "热门" && workspace.loadedBrowseInstance(for: "首页") === popular)
    workspace.moveHistory(-1)
    #expect(
        workspace.homeSection == "推荐" && workspace.loadedBrowseInstance(for: "首页") === recommended)
    workspace.moveHistory(1)
    let index = workspace.historyIndex
    workspace.selected = "playing-video"
    #expect(workspace.canBack)
    workspace.moveHistory(-1)
    #expect(workspace.selected == nil && workspace.historyIndex == index)
    #expect(workspace.loadedBrowseInstance(for: "首页") === popular)
    workspace.moveHistory(-1)
    #expect(workspace.homeSection == "推荐" && workspace.historyIndex == index - 1)
    #expect(requests == 6 && recommended.browseRevision == 1 && popular.browseRevision == 1)
}

@MainActor
@Test(arguments: [false, true])
func persistentBrowseEmptyAndErrorPagesAreNotRetriedOnReturnButExplicitRefreshWorks(_ failure: Bool)
    async throws
{
    var requests: [String] = []
    var fail = failure
    let workspace = persistentWorkspace { request in
        requests.append("\(request.homeSection):\(request.page)")
        if request.homeSection == "推荐" {
            if fail { throw URLError(.timedOut) }
            return BrowsePageResult(videos: [], next: nil)
        }
        return persistentPage(request)
    }
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let original = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await original.browseTask?.value
    let revision = original.browseRevision
    workspace.selectBrowseSection(destination: "首页", section: "热门")
    await workspace.loadedBrowseInstance(for: "首页")?.browseTask?.value
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    #expect(requests == ["推荐:1", "热门:1", "热门:2", "热门:3"])
    #expect(original.browseRevision == revision && original.browseLoadAttempted)
    #expect((original.browseError != nil) == failure)
    fail = false
    workspace.refresh()
    await original.browseTask?.value
    #expect(requests.last == "推荐:1" && requests.count == 5)
    #expect(original.browseError == nil && original.browseRevision == revision + 1)
}

@MainActor
@Test func persistentBrowseSwitchingDuringLoadDoesNotRestartTheOriginalRequest() async throws {
    let gate = PersistentBrowseGate()
    var requests: [String] = []
    let workspace = persistentWorkspace { request in
        requests.append("\(request.homeSection):\(request.page)")
        if request.homeSection == "推荐" && request.page == 1 { await gate.suspend() }
        return persistentPage(request)
    }
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let original = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await gate.waitForEntry()
    let generation = original.browseGeneration
    workspace.selectBrowseSection(destination: "首页", section: "热门")
    await workspace.loadedBrowseInstance(for: "首页")?.browseTask?.value
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    #expect(original.loading && original.browseGeneration == generation)
    gate.release()
    await original.browseTask?.value
    #expect(requests.filter { $0.hasPrefix("推荐:") } == ["推荐:1", "推荐:2", "推荐:3"])
    #expect(original.browseRevision == 1 && original.page == 3)
}

@MainActor
@Test func persistentBrowseLateStartupProfileKeepsAlreadyLoadedPageAndPublishesToItsOwner()
    async throws
{
    let gate = PersistentBrowseGate()
    var calls = 0
    var profiles = 0
    let workspace = persistentWorkspace(
        profileLoader: {
            profiles += 1
            await gate.suspend()
            return UserProfile(id: 8, name: "离线测试")
        },
        loader: { request in
            calls += 1
            return persistentPage(request)
        })
    let startup = Task { await workspace.start() }
    await gate.waitForEntry()
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let original = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await original.browseTask?.value
    gate.release()
    await startup.value
    await workspace.start()
    #expect(calls == 3 && original.browseRevision == 1 && profiles == 1)
    #expect(workspace.profile?.id == 8 && original.profile?.id == 8)
}

@MainActor
@Test func persistentBrowseLateStartupProfileLoadsAnEarlyAnonymousRestrictedPageOnce() async throws
{
    let gate = PersistentBrowseGate()
    var calls = 0
    let workspace = persistentWorkspace(
        profileLoader: {
            await gate.suspend()
            return UserProfile(id: 8, name: "离线测试")
        },
        loader: { request in
            calls += 1
            return persistentPage(request)
        })
    let startup = Task { await workspace.start() }
    await gate.waitForEntry()
    workspace.selectBrowseSection(destination: "动态", section: "视频")
    let page = try #require(workspace.loadedBrowseInstance(for: "动态"))
    #expect(calls == 0 && !page.browseLoadAttempted)
    gate.release()
    await startup.value
    await page.browseTask?.value
    #expect(calls == 3 && page.browseRevision == 1 && page.profile?.id == 8)
}

@MainActor
@Test func persistentBrowseLateStartupProfileNeverForcesTheCurrentlySelectedVideoToReload()
    async throws
{
    let gate = PersistentBrowseGate()
    let workspace = persistentWorkspace(
        profileLoader: {
            await gate.suspend()
            return UserProfile(id: 8, name: "离线测试")
        }, loader: persistentPage)
    let startup = Task { await workspace.start() }
    await gate.waitForEntry()
    let tab = SessionTab(video: Video(bvid: "playing-video", title: "已载入视频"))
    workspace.tabs = [tab]
    let player = workspace.playbackInstance(for: tab)
    workspace.selected = tab.id
    gate.release()
    await startup.value
    #expect(workspace.selected == tab.id && player.videoTask == nil && !player.videoLoading)
    #expect(player.profile?.id == 8 && workspace.browseInstances.isEmpty)
}

@MainActor
@Test func persistentBrowseLateStartupIdentityCannotOverwriteAnAccountChange() async {
    let gate = PersistentBrowseGate()
    var calls = 0
    let workspace = persistentWorkspace(
        profileLoader: {
            await gate.suspend()
            return UserProfile(id: 8, name: "旧账号")
        },
        loader: { request in
            calls += 1
            return persistentPage(request)
        })
    let startup = Task { await workspace.start() }
    await gate.waitForEntry()
    workspace.accountGeneration = UUID()
    workspace.profile = UserProfile(id: 9, name: "新账号")
    gate.release()
    await startup.value
    #expect(workspace.profile?.id == 9 && calls == 0 && workspace.browseInstances.isEmpty)
}

@MainActor
@Test func persistentBrowseInvalidationCancelsLateOldResultsAndAllowsOneFreshLoad() async throws {
    let gate = PersistentBrowseGate()
    var calls = 0
    let workspace = persistentWorkspace { _ in
        calls += 1
        let old = calls == 1
        if old { await gate.suspend() }
        return BrowsePageResult(
            videos: [Video(bvid: old ? "old" : "new", title: "离线测试")], next: nil)
    }
    workspace.selectBrowseSection(destination: "首页", section: "推荐")
    let page = try #require(workspace.loadedBrowseInstance(for: "首页"))
    await gate.waitForEntry()
    let old = try #require(page.browseTask)
    page.invalidateBrowseCache()
    #expect(
        !page.browseLoadAttempted && page.videos.isEmpty && !page.loading && page.browseError == nil
    )
    page.loadBrowseIfNeeded()
    await page.browseTask?.value
    gate.release()
    await old.value
    #expect(page.videos.map(\.id) == ["new"] && calls == 2 && page.browseRevision == 1)
    #expect(page.browseLoadAttempted && !page.loading)
}

@MainActor
@Test func persistentBrowseMainHistoryRetainsItsExplicitNavigationRefreshPolicy() async throws {
    var calls = 0
    let workspace = persistentWorkspace { request in
        calls += 1
        return persistentPage(request)
    }
    workspace.profile = UserProfile(id: 8, name: "离线测试")
    workspace.navigate("历史")
    let page = try #require(workspace.loadedBrowseInstance(for: "历史"))
    await page.browseTask?.value
    workspace.navigate("历史")
    await page.browseTask?.value
    #expect(calls == 6 && page.browseRevision == 2)
    #expect(workspace.history == ["动态:视频", "历史"])
}
