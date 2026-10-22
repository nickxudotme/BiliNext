import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@Test func searchTabIdentityAndShareURLPreserveUnicodeAndPunctuation() throws {
    let keyword = "Swift UI / 中文 + #?"
    let id = SearchResultsTab.id(keyword)
    #expect(SearchResultsTab.keyword(id) == keyword)
    let url = try #require(SearchResultsTab.url(id))
    let parts = try #require(URLComponents(string: url))
    #expect(parts.host == "search.bilibili.com")
    #expect(parts.queryItems?.first?.value == keyword)
    #expect(SearchResultsTab.keyword("space:7") == nil)
    #expect(SearchResultsTab.keyword("search:!") == nil)
}

@MainActor
@Test func globalSearchHasIndependentRetainedResultTabs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var requests: [String] = []
    let model = AppModel(
        sessionStore: SessionStore(directory: directory), api: BilibiliAPI(restoreSession: false),
        browsePageLoader: { request in
            requests.append(request.keyword)
            return BrowsePageResult(
                videos: [Video(bvid: request.keyword + "-video", title: request.keyword)], next: nil
            )
        })
    let originalMenu = model.menu
    model.search("  Alpha  ")
    let alphaID = SearchResultsTab.id("Alpha")
    let alpha = try #require(model.playbackInstances[alphaID])
    await alpha.browseTask?.value
    #expect(model.selected == alphaID && model.menu == originalMenu)
    #expect(alpha.selected == nil && alpha.menu == .search && alpha.query == "Alpha")
    alpha.searchOrder = "click"
    model.search("Beta")
    let beta = try #require(model.playbackInstances[SearchResultsTab.id("Beta")])
    await beta.browseTask?.value
    model.search("Alpha")
    #expect(model.playbackInstances[alphaID] === alpha)
    #expect(alpha.searchOrder == "click" && alpha.videos.first?.title == "Alpha")
    #expect(requests == ["Alpha", "Beta"] && model.tabs.count == 2)
    model.toggleMiniPlayer()
    #expect(!model.miniPlayer)
    let restored = try SessionStore(directory: directory).read()
    #expect(restored.map(\.id) == model.tabs.map(\.id))
    model.close(alphaID)
    #expect(model.playbackInstances[alphaID] == nil)
}
