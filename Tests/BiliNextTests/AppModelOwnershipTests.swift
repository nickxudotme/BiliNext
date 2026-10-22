import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func retainedPagesInheritWorkspaceServicesAndKeepLocalState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var folderReads = 0
    var subtitleReads = 0
    let workspace = AppModel(
        sessionStore: SessionStore(directory: directory), api: BilibiliAPI(restoreSession: false),
        favoriteFolderLoader: { _ in
            folderReads += 1
            return []
        },
        subtitleLoader: { _ in
            subtitleReads += 1
            return []
        })
    let browse = workspace.browseInstance(for: .home)
    let playback = workspace.playbackInstance(
        for: SessionTab(video: Video(bvid: "BVoffline", title: "测试")))
    #expect(workspace.scope == .workspace)
    for page in [browse, playback] {
        #expect(page.scope == .page)
        #expect(page.services === workspace.services)
        #expect(page.api === workspace.api)
        #expect(page.downloads === workspace.downloads)
        #expect(page.hoverPreview === workspace.hoverPreview)
        #expect(page.playbackPrefetch === workspace.playbackPrefetch)
        #expect(page.historyOutbox === workspace.historyOutbox)
        #expect(page.followedLives === workspace.followedLives)
        #expect(page.watchLaterSynchronization === workspace.watchLaterSynchronization)
        #expect(page.tabOwner === workspace)
        _ = try await page.favoriteFolderLoader(1)
        _ = try await page.subtitleLoader(
            SubtitleTrack(language: "测试", url: URL(string: "https://example.com/offline")!))
    }
    #expect(folderReads == 2)
    #expect(subtitleReads == 2)
    browse.query = "只在此页"
    playback.time = 42
    #expect(workspace.query.isEmpty && playback.query.isEmpty)
    #expect(workspace.time == 0 && browse.time == 0)
    #expect(browse.playbackClock !== playback.playbackClock)
    #expect(browse.smartSubtitles !== playback.smartSubtitles)
    #expect(workspace.browseInstance(for: .home) === browse)
    #expect(
        workspace.playbackInstance(for: SessionTab(video: Video(bvid: "BVoffline", title: "测试")))
            === playback)
}

@MainActor
@Test func workspacesKeepServicesAndAccountCachesIndependent() {
    let first = AppModel(api: BilibiliAPI(restoreSession: false))
    let second = AppModel(api: BilibiliAPI(restoreSession: false))
    #expect(first.services !== second.services)
    #expect(first.playbackPrefetch !== second.playbackPrefetch)
    #expect(first.followedLives !== second.followedLives)
    #expect(first.historyOutbox !== second.historyOutbox)
    #expect(first.historyStoreURL == nil && second.historyStoreURL == nil)
    let lives = first.followedLives
    first.accountGeneration = UUID()
    #expect(first.followedLives === lives)
    #expect(first.services.owner === first)
}

@MainActor
@Test func sharedServicesDoNotRetainTheirWorkspace() {
    weak var released: AppModel?
    var retainedServices: AppModelServices?
    do {
        let workspace = AppModel(api: BilibiliAPI(restoreSession: false))
        released = workspace
        retainedServices = workspace.services
        _ = workspace.historyOutbox
    }
    #expect(released == nil)
    #expect(retainedServices?.owner == nil)
}
