import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
private final class BrowsePageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func browsingModel(
    managesPlaybackTabs: Bool = false,
    loader: @escaping (BrowsePageRequest) async throws -> BrowsePageResult
) -> AppModel {
    let model = AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        managesPlaybackTabs: managesPlaybackTabs, api: BilibiliAPI(restoreSession: false),
        browsePageLoader: loader)
    model.menu = .home
    return model
}

private func browsingVideo(_ number: Int) -> Video {
    Video(bvid: "BV\(number)", title: "视频 \(number)")
}

@MainActor
@Test func browsingPrefetchParentRoutesThroughTheInjectedLoader() async {
    var requests: [Int] = []
    let workspace = browsingModel(managesPlaybackTabs: true) { request in
        requests.append(request.page)
        return BrowsePageResult(
            videos: [browsingVideo(request.page)], next: String(request.page + 1))
    }
    workspace.refresh()
    let page = workspace.browseInstance(for: .home)
    await page.browseTask?.value
    #expect(requests == [1, 2, 3])
    #expect(page.videos.count == 3 && page.browseRevision == 1 && workspace.videos.isEmpty)
}

@MainActor
@Test func browsingPrefetchPublishesFirstPageThenBuffersThreeAndTwoPages() async {
    let gate = BrowsePageGate()
    var pauseSecondPage = true
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        if request.page == 2 && pauseSecondPage { await gate.suspend() }
        let video = browsingVideo(request.page)
        return BrowsePageResult(videos: [video, video], next: String(request.page + 1))
    }
    model.refresh()
    await gate.waitForEntry()
    #expect(model.videos.map(\.id) == [browsingVideo(1).id])
    #expect(model.loading && model.browseRevision == 1)
    #expect(model.page == 1 && model.offset == "2")
    pauseSecondPage = false
    gate.release()
    await model.browseTask?.value
    #expect(requests == [1, 2, 3])
    #expect(model.videos.map(\.id) == (1...3).map { browsingVideo($0).id })
    #expect(model.hasMore && !model.loading && model.browseRevision == 1)
    #expect(model.cachedLists["首页:推荐"]?.count == 3)
    model.loadMoreIfNeeded()
    model.loadMoreIfNeeded()  // Synchronous loading guard prevents an overlapping batch.
    await model.browseTask?.value
    #expect(requests == [1, 2, 3, 4, 5])
    #expect(model.videos.count == 5 && model.page == 5 && model.offset == "6")
    #expect(model.browseRevision == 1)
    model.refresh()
    await model.browseTask?.value
    #expect(model.videos.map(\.id) == (1...3).map { browsingVideo($0).id })
    #expect(model.browseRevision == 2)  // The same successful refresh still reveals the list.
}

@MainActor
@Test func browsingPrefetchAppendKeepsCommittedSearchWhileInputIsEdited() async {
    var requests: [BrowsePageRequest] = []
    let model = browsingModel { request in
        requests.append(request)
        return BrowsePageResult(
            videos: [browsingVideo(request.page)], next: String(request.page + 1))
    }
    model.menu = .search
    model.query = "已提交关键词"
    model.refresh()
    await model.browseTask?.value
    model.query = ""
    model.searchOrder = "pubdate"
    model.loadMoreIfNeeded()
    await model.browseTask?.value
    #expect(requests.map(\.page) == [1, 2, 3, 4, 5])
    #expect(requests.allSatisfy { $0.keyword == "已提交关键词" && $0.searchOrder == "totalrank" })
    #expect(model.videos.count == 5 && model.browseRevision == 1)
    #expect(model.cachedLists["搜索:已提交关键词:totalrank"]?.count == 5)
}

@MainActor
@Test(arguments: ["推荐", "热门", "搜索", "收藏", "历史搜索", "稍后再看"])
func browsingPrefetchFollowsNumericNextPagesAndSnapshotsSelection(_ destination: String) async {
    var requests: [BrowsePageRequest] = []
    let model = browsingModel { request in
        requests.append(request)
        let next = request.page == 1 ? "3" : request.page == 3 ? "7" : nil
        return BrowsePageResult(
            videos: [browsingVideo(request.page)], next: next,
            folderID: request.destination == .favorites ? 42 : nil)
    }
    model.profile = UserProfile(id: 8, name: "测试用户")
    switch destination {
    case "推荐", "热门": model.homeSection = destination
    case "历史搜索":
        model.menu = .history
        model.libraryQuery = "  风景  "
    default: model.menu = BrowseDestination(rawValue: destination)!
    }
    model.query = "  测试关键词  "
    model.searchOrder = "pubdate"
    model.favoriteOrder = "view"
    model.folderID = 9
    model.refresh()
    await model.browseTask?.value
    #expect(requests.map(\.page) == [1, 3, 7])
    #expect(requests.map(\.keyword) == Array(repeating: "测试关键词", count: 3))
    #expect(requests.allSatisfy { $0.searchOrder == "pubdate" && $0.favoriteOrder == "view" })
    #expect(requests.map(\.reloadFolders) == [true, false, false])
    #expect(!model.hasMore && model.page == 7)
    if destination == "收藏" {
        #expect(requests.map(\.folderID) == [9, 42, 42])
        #expect(model.folderID == 42 && model.cachedLists["收藏:42::view"]?.count == 3)
    }
    if destination == "历史搜索" {
        #expect(requests.allSatisfy { !$0.usesCursor && $0.libraryKeyword == "风景" })
    }
}

@MainActor
@Test(arguments: [BrowseDestination.dynamic, .favorites, .history, .watchLater])
func browsingPrefetchExplicitNextSurvivesFilteredEmptyAndDuplicatePages(
    _ destination: BrowseDestination
) async {
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        let videos =
            request.page == 2 ? [] : [browsingVideo(request.page == 4 ? 3 : request.page)]
        return BrowsePageResult(
            videos: videos, next: request.page < 5 ? String(request.page + 1) : nil)
    }
    model.menu = destination
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1, 2, 3])
    #expect(model.videos.map(\.id) == [browsingVideo(1).id, browsingVideo(3).id])
    #expect(model.hasMore)
    model.loadMoreIfNeeded()
    await model.browseTask?.value
    #expect(requests == [1, 2, 3, 4, 5])
    #expect(
        model.videos.map(\.id) == [browsingVideo(1).id, browsingVideo(3).id, browsingVideo(5).id])
    #expect(!model.hasMore && model.browseRevision == 1)
}

@MainActor
@Test func browsingPrefetchFilteredEmptyBatchRetainsNextPageForExplicitContinuation() async {
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        return BrowsePageResult(
            videos: request.page <= 3 ? [] : [browsingVideo(4)],
            next: request.page < 4 ? String(request.page + 1) : nil)
    }
    model.menu = .history
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1, 2, 3] && model.videos.isEmpty)
    #expect(model.hasMore && model.page == 3 && model.offset == "4" && !model.loading)
    #expect(model.browseRevision == 1)
    model.loadMoreIfNeeded()
    #expect(requests == [1, 2, 3])  // Empty batches continue only on an explicit user action.
    model.refresh(more: true)
    await model.browseTask?.value
    #expect(requests == [1, 2, 3, 4])
    #expect(model.videos.map(\.id) == [browsingVideo(4).id])
    #expect(!model.hasMore && model.page == 4 && model.browseRevision == 1)
}

@MainActor
@Test func browsingPrefetchStopsRepeatedCursorEvenWhenPageContainsNewVideos() async {
    var requests: [String?] = []
    let model = browsingModel { request in
        requests.append(request.offset)
        return BrowsePageResult(videos: [browsingVideo(request.page)], next: "same-cursor")
    }
    model.menu = .dynamic
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [nil, "same-cursor"])
    #expect(model.videos.count == 2 && !model.hasMore)
    model.loadMoreIfNeeded()
    #expect(requests.count == 2)
}

@MainActor
@Test func browsingPrefetchStopsCursorCyclesAcrossSeparateBatches() async {
    var requests: [String?] = []
    let model = browsingModel { request in
        requests.append(request.offset)
        let next =
            request.offset == nil
            ? "a" : request.offset == "a" ? "b" : request.offset == "b" ? "c" : "a"
        return BrowsePageResult(videos: [browsingVideo(request.page)], next: next)
    }
    model.menu = .history
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [nil, "a", "b"] && model.hasMore)
    model.loadMoreIfNeeded()
    await model.browseTask?.value
    #expect(requests == [nil, "a", "b", "c"])
    #expect(model.videos.count == 4 && !model.hasMore)
}

@MainActor
@Test(arguments: ["", "1", "0", "invalid"])
func browsingPrefetchDoesNotFollowInvalidOrRepeatedNumericNext(_ next: String) async {
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        return BrowsePageResult(videos: [browsingVideo(1)], next: next)
    }
    model.menu = .favorites
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1] && model.videos.count == 1 && !model.hasMore)
}

@MainActor
@Test(arguments: [false, true])
func browsingPrefetchArrayEndpointsStopEmptyOrFullyRepeatedPages(_ duplicate: Bool) async {
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        return BrowsePageResult(
            videos: request.page == 1 || duplicate ? [browsingVideo(1)] : [],
            next: String(request.page + 1))
    }
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1, 2])
    #expect(model.videos.count == 1 && !model.hasMore)
}

@MainActor
@Test func browsingPrefetchTerminalPageAndEmptyRefreshDoNotRepeat() async {
    var requests: [Int] = []
    var empty = false
    let model = browsingModel { request in
        requests.append(request.page)
        return BrowsePageResult(videos: empty ? [] : [browsingVideo(1)], next: nil)
    }
    model.homeSection = "排行榜"
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1] && !model.hasMore && model.browseRevision == 1)
    empty = true
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1, 1] && model.videos.isEmpty && model.browseRevision == 2)
}

@MainActor
@Test func browsingPrefetchFirstPageFailureRetriesReplacementInsteadOfAppendingCachedPages() async {
    var fail = true
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        if fail { throw URLError(.notConnectedToInternet) }
        return BrowsePageResult(videos: [browsingVideo(1)], next: nil)
    }
    model.cachedLists["首页:推荐"] = [browsingVideo(90), browsingVideo(91)]
    model.refresh()
    await model.browseTask?.value
    #expect(model.videos.count == 2 && model.page == 0 && !model.hasMore)
    #expect(model.browseError != nil && !model.loading && model.browseRevision == 0)
    fail = false
    model.retryBrowse()
    await model.browseTask?.value
    #expect(requests == [1, 1])
    #expect(model.videos.map(\.id) == [browsingVideo(1).id])
    #expect(model.browseError == nil && model.browseRevision == 1)
}

@MainActor
@Test func browsingPrefetchLaterPageFailuresKeepPagesAndRetryTheSameNextPage() async {
    var failures = 2
    var requests: [Int] = []
    let model = browsingModel { request in
        requests.append(request.page)
        if request.page == 2 && failures > 0 {
            failures -= 1
            throw URLError(.timedOut)
        }
        return BrowsePageResult(
            videos: [browsingVideo(request.page)],
            next: request.page < 3 ? String(request.page + 1) : nil)
    }
    model.refresh()
    await model.browseTask?.value
    #expect(requests == [1, 2] && model.videos.count == 1)
    #expect(model.page == 1 && model.offset == "2" && model.hasMore)
    #expect(model.browseError != nil && !model.loading)
    model.loadMoreIfNeeded()
    #expect(requests == [1, 2])  // An error requires an explicit retry.
    model.retryBrowse()
    await model.browseTask?.value
    #expect(requests == [1, 2, 2] && model.browseError != nil)
    model.retryBrowse()
    await model.browseTask?.value
    #expect(requests == [1, 2, 2, 2, 3])
    #expect(model.videos.map(\.id) == (1...3).map { browsingVideo($0).id })
    #expect(model.browseError == nil && !model.hasMore && model.browseRevision == 1)
}

@MainActor
@Test func browsingPrefetchLateCancelledResultCannotReplaceNewListOrEndItsLoading() async throws {
    let oldGate = BrowsePageGate()
    let newGate = BrowsePageGate()
    let model = browsingModel { request in
        if request.keyword == "旧搜索" {
            await oldGate.suspend()  // Deliberately ignore Task cancellation.
            return BrowsePageResult(videos: [browsingVideo(90)], next: nil, folderID: 90)
        }
        await newGate.suspend()
        return BrowsePageResult(videos: [browsingVideo(1)], next: nil)
    }
    model.menu = .search
    model.query = "旧搜索"
    model.refresh()
    await oldGate.waitForEntry()
    let oldTask = try #require(model.browseTask)
    model.query = "新搜索"
    model.refresh()
    await newGate.waitForEntry()
    oldGate.release()
    await oldTask.value
    #expect(model.loading && model.videos.isEmpty && model.browseRevision == 0)
    #expect(model.folderID == 0 && model.browseError == nil)
    newGate.release()
    await model.browseTask?.value
    #expect(model.videos.map(\.id) == [browsingVideo(1).id])
    #expect(!model.loading && model.browseRevision == 1)
    #expect(model.cachedLists["搜索:旧搜索:totalrank"] == nil)
}

@MainActor
@Test func browsingPrefetchCancelledBeforeStartCannotLoadOrPoisonNewCursorLedger() async throws {
    var requests: [String?] = []
    let model = browsingModel { request in
        requests.append(request.offset)
        return BrowsePageResult(
            videos: [browsingVideo(request.page)], next: request.offset == nil ? "old" : nil)
    }
    model.menu = .dynamic
    model.profile = UserProfile(id: 8, name: "测试用户")
    model.videos = [browsingVideo(90)]
    model.page = 1
    model.offset = "old"
    model.hasMore = true
    model.refresh(more: true)
    let oldTask = try #require(model.browseTask)
    model.refresh()  // Neither Task has started while this actor turn is synchronous.
    await model.browseTask?.value
    await oldTask.value
    #expect(requests == [nil, "old"])
    #expect(model.videos.map(\.id) == [browsingVideo(1).id, browsingVideo(2).id])
    #expect(!model.hasMore && !model.loading && model.browseRevision == 1)
}
