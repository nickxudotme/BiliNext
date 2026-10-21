import AppKit
import BiliNextCore
import Combine
import Testing

@testable import BiliNext

@MainActor
private final class GridRequestLog {
    var pages: [Int] = []
}

@MainActor
private struct GridReturnFixture {
    let model: AppModel
    let coordinator: NativeVideoGrid.Coordinator
    let scroll: VideoGridScrollView
    let collection: VideoGridCollectionView
    let requests: GridRequestLog

    func scrollNearBottom() {
        let height = collection.collectionViewLayout!.collectionViewContentSize.height
        scroll.contentView.scroll(
            to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height - 80)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
private func makeGridReturnFixture(count: Int = 24) -> GridReturnFixture {
    _ = NSApplication.shared
    let requests = GridRequestLog()
    let model = AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        managesPlaybackTabs: false, api: BilibiliAPI(restoreSession: false),
        browsePageLoader: { request in
            requests.pages.append(request.page)
            return BrowsePageResult(
                videos: [Video(bvid: "BV_appended_\(request.page)", title: "新卡片")], next: nil)
        }, subtitlePreferences: UserDefaults(suiteName: UUID().uuidString)!)
    if let observer = model.observer {
        model.player.removeTimeObserver(observer)
        model.observer = nil
    }
    model.playbackTabActive = false
    model.menu = .home
    model.videos = (0..<count).map { Video(bvid: "BV_grid_\($0)", title: "卡片 \($0)") }
    model.browseRevision = 1
    model.page = 3
    model.offset = "4"
    let coordinator = NativeVideoGrid.Coordinator(model: model, active: true)
    let scroll = VideoGridScrollView(frame: NSRect(x: 0, y: 0, width: 930, height: 520))
    let collection = VideoGridCollectionView(frame: scroll.contentView.bounds)
    collection.collectionViewLayout = NSCollectionViewFlowLayout()
    collection.delegate = coordinator
    collection.dataSource = coordinator
    collection.register(
        VideoGridItem.self, forItemWithIdentifier: NativeVideoGrid.Coordinator.itemID)
    collection.register(
        VideoGridFooter.self,
        forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
        withIdentifier: NativeVideoGrid.Coordinator.footerID)
    scroll.documentView = collection
    coordinator.collection = collection
    coordinator.scroll = scroll
    coordinator.observeBounds()
    coordinator.update(active: true, reduceMotion: true)
    collection.layoutSubtreeIfNeeded()
    collection.frame.size.height = collection.collectionViewLayout!.collectionViewContentSize.height
    return GridReturnFixture(
        model: model, coordinator: coordinator, scroll: scroll,
        collection: collection, requests: requests)
}

@Test @MainActor func nativeGridReturningToSamePageKeepsScrollAndRevealState() async throws {
    let fixture = makeGridReturnFixture()
    defer { fixture.coordinator.stop() }
    try await Task.sleep(for: .milliseconds(20))
    fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
    _ = fixture.coordinator.revealState.claim(fixture.model.videos.prefix(12).map(\.id))
    try await Task.sleep(for: .milliseconds(20))
    let position = fixture.scroll.contentView.bounds.origin
    let revealed = fixture.coordinator.revealState.revealed
    #expect(position.y > 0)
    fixture.coordinator.update(active: false, reduceMotion: true)
    fixture.coordinator.update(active: true, reduceMotion: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.scroll.contentView.bounds.origin == position)
    #expect(fixture.coordinator.revealState.revealed == revealed)
    #expect(fixture.coordinator.collection === fixture.collection)
    #expect(fixture.model.browseRevision == 1)
    #expect(fixture.requests.pages.isEmpty)
}

@Test @MainActor func nativeGridNearBottomReturnWaitsForActualScrolling() async throws {
    let fixture = makeGridReturnFixture()
    defer { fixture.coordinator.stop() }
    try await Task.sleep(for: .milliseconds(20))
    fixture.coordinator.update(active: false, reduceMotion: true)
    fixture.scrollNearBottom()
    fixture.model.hasMore = true
    fixture.coordinator.update(active: false, reduceMotion: true)
    let position = fixture.scroll.contentView.bounds.origin
    fixture.coordinator.update(active: true, reduceMotion: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.requests.pages.isEmpty)
    #expect(fixture.scroll.contentView.bounds.origin == position)
    fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: position.y + 20))
    fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
    try await Task.sleep(for: .milliseconds(20))
    await fixture.model.browseTask?.value
    #expect(fixture.requests.pages == [4])
    #expect(fixture.model.videos.count == 25)
}

@Test @MainActor func nativeGridLeavingPageInvalidatesAnAlreadyQueuedBottomCheck() async throws {
    let fixture = makeGridReturnFixture()
    defer { fixture.coordinator.stop() }
    try await Task.sleep(for: .milliseconds(20))
    fixture.scrollNearBottom()
    fixture.model.hasMore = true
    fixture.coordinator.scheduleBottomCheck()
    // Switch away and back in the same actor turn, before the queued check can run.
    fixture.coordinator.update(active: false, reduceMotion: true)
    fixture.coordinator.update(active: true, reduceMotion: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.requests.pages.isEmpty)
}

@Test @MainActor func nativeGridLoadingCompletionStillFillsAShortViewport() async throws {
    let fixture = makeGridReturnFixture(count: 3)
    defer { fixture.coordinator.stop() }
    try await Task.sleep(for: .milliseconds(20))
    fixture.model.hasMore = true
    fixture.model.loading = true
    fixture.coordinator.update(active: true, reduceMotion: true)
    fixture.model.loading = false
    fixture.coordinator.update(active: true, reduceMotion: true)
    try await Task.sleep(for: .milliseconds(20))
    await fixture.model.browseTask?.value
    #expect(fixture.requests.pages == [4])
}

@Test @MainActor func inactiveGridUpdatesDoNotPublishAndDeactivationWaitsForViewUpdate() async {
    let model = AppModel(api: BilibiliAPI(restoreSession: false))
    let coordinator = NativeVideoGrid.Coordinator(model: model, active: false)
    var changes = 0
    let scrolling = coordinator.interaction.objectWillChange.sink { changes += 1 }
    let preview = model.hoverPreview.objectWillChange.sink { changes += 1 }
    for _ in 0..<10 { coordinator.update(active: false, reduceMotion: false) }
    #expect(changes == 0)
    coordinator.update(active: true, reduceMotion: false)
    coordinator.interaction.scrolling = true
    changes = 0
    coordinator.update(active: false, reduceMotion: false)
    #expect(changes == 0)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!coordinator.interaction.scrolling)
    #expect(changes == 1)
    withExtendedLifetime((scrolling, preview)) {}
}
