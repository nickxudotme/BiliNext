import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@Suite(.serialized)
@MainActor
struct WatchLaterSynchronizationTests {
    @Test(arguments: ["home", "playback"])
    func addingElsewhereUpdatesTheRetainedLibrary(_ source: String) async throws {
        let fixture = WatchLaterFixture(count: 6)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let original = library.videos
        let revision = library.browseRevision
        fixture.model.navigate(.home)
        let page =
            source == "home"
            ? fixture.model.browseInstance(for: .home)
            : fixture.model.playbackInstance(for: SessionTab(video: fixture.video(100)))
        let added = fixture.video(101)
        await page.changeWatchLater(added)?.value
        #expect(library.videos == [added] + original)
        #expect(library.cachedLists[BrowseDestination.watchLater.rawValue] == library.videos)
        fixture.model.navigate(.watchLater)
        #expect(fixture.model.browseInstance(for: .watchLater) === library)
        #expect(library.browseRevision == revision && fixture.pages == [1])
    }

    @Test func removalAndUndoKeepTheLoadedListAndPagination() async throws {
        let fixture = WatchLaterFixture(count: 65)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let original = library.videos
        let removed = original[25]
        let revision = library.browseRevision
        let context = library.browseContext
        await library.changeWatchLater(removed, remove: true)?.value
        #expect(library.videos == original.filter { $0.id != removed.id })
        #expect(library.removedLater == removed && !library.loading)
        #expect(library.page == 3 && library.offset == "4" && library.hasMore)
        #expect(library.browseContext?.page == context?.page)
        #expect(library.browseRevision == revision && fixture.pages == [1, 2, 3])
        await library.changeWatchLater(removed)?.value
        #expect(library.videos == original && library.removedLater == nil)
        #expect(library.cachedLists[BrowseDestination.watchLater.rawValue] == original)
        #expect(library.page == 3 && library.offset == "4" && library.hasMore)
        #expect(library.browseRevision == revision && fixture.pages == [1, 2, 3])
    }

    @Test func failedWriteLeavesResultsAndPaginationUntouched() async throws {
        let fixture = WatchLaterFixture(count: 65, responseCode: -403)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let original = library.videos
        await library.changeWatchLater(original[4], remove: true)?.value
        #expect(library.videos == original && library.removedLater == nil)
        #expect(library.cachedLists[BrowseDestination.watchLater.rawValue] == original)
        #expect(library.page == 3 && library.offset == "4" && library.hasMore)
        #expect(!fixture.model.watchLaterSynchronization.needsPaginationRestart(library))
        #expect(
            library.toast == APIError(code: -403, message: "mock rejection").localizedDescription)
        #expect(library.libraryBusy.isEmpty && fixture.writeCount == 1)
    }

    @Test func latePageCannotResurrectARemovedVideo() async throws {
        let fixture = WatchLaterFixture(count: 65)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let removed = library.videos[15]
        fixture.holdRead = true
        library.refresh(more: true)
        await fixture.waitForHeldRead()
        await library.changeWatchLater(removed, remove: true)?.value
        fixture.resumeRead(
            BrowsePageResult(videos: [removed] + Array(fixture.server.suffix(5)), next: nil))
        await library.browseTask?.value
        #expect(!library.videos.contains(where: { $0.id == removed.id }))
        #expect(library.videos.count == 64)
        #expect(library.hasMore)
        #expect(fixture.model.watchLaterSynchronization.needsPaginationRestart(library))
    }

    @Test func recheckingPageBoundariesDoesNotSkipVideosAfterRemoval() async throws {
        let fixture = WatchLaterFixture(count: 65)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let removed = library.videos[0]
        await library.changeWatchLater(removed, remove: true)?.value
        fixture.server.removeAll { $0.id == removed.id }
        library.refresh(more: true)
        await library.browseTask?.value
        #expect(library.videos.count == 59 && library.hasMore)
        library.refresh(more: true)
        await library.browseTask?.value
        #expect(library.videos == fixture.server && !library.hasMore)
        #expect(fixture.pages == [1, 2, 3, 1, 2, 3, 4])
    }

    @Test func accountGenerationAndDuplicateWritesAreIsolated() async throws {
        let fixture = WatchLaterFixture(count: 6, holdWrites: true)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let home = fixture.model.browseInstance(for: .home)
        let added = fixture.video(100)
        let original = library.videos
        let pending = try #require(home.changeWatchLater(added))
        #expect(library.libraryBusy.contains(added.id))
        #expect(library.changeWatchLater(added) == nil)
        await fixture.waitForWrite()
        let newlyOpened = fixture.model.playbackInstance(for: SessionTab(video: added))
        #expect(newlyOpened.libraryBusy.contains(added.id))
        #expect(newlyOpened.changeWatchLater(added) == nil)
        fixture.model.accountGeneration = UUID()
        #expect(library.libraryBusy.isEmpty)
        fixture.respondToWrite()
        await pending.value
        #expect(library.videos == original && home.toast == nil)
        #expect(library.libraryBusy.isEmpty)
        #expect(newlyOpened.libraryBusy.isEmpty)
        #expect(fixture.writeCount == 1)
    }

    @Test func differentCookieAccountNeverSendsTheWrite() async throws {
        let fixture = WatchLaterFixture(count: 6)
        defer { fixture.close() }
        let library = await fixture.loadLibrary()
        let original = library.videos
        fixture.model.profile = UserProfile(id: 43, name: "另一账号")
        fixture.model.accountGeneration = UUID()
        await library.changeWatchLater(fixture.video(100))?.value
        #expect(fixture.writeCount == 0 && library.videos == original)
    }
}

@MainActor
private final class WatchLaterFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let network: WatchLaterNetwork
    lazy var model: AppModel = {
        let model = AppModel(
            sessionStore: SessionStore(directory: directory), api: network.api,
            browsePageLoader: { [weak self] request in
                guard let self else { throw CancellationError() }
                guard request.destination == .watchLater else {
                    return BrowsePageResult(videos: [], next: nil)
                }
                pages.append(request.page)
                if holdRead {
                    holdRead = false
                    return await withCheckedContinuation { self.heldRead = $0 }
                }
                let start = (request.page - 1) * 20
                return BrowsePageResult(
                    videos: Array(server.dropFirst(start).prefix(20)),
                    next: start + 20 < server.count ? String(request.page + 1) : nil)
            })
        model.profile = UserProfile(id: 42, name: "离线测试")
        return model
    }()
    var server: [Video]
    var pages: [Int] = []
    var holdRead = false
    var heldRead: CheckedContinuation<BrowsePageResult, Never>?
    var writeCount: Int { network.writeCount }

    init(count: Int, responseCode: Int = 0, holdWrites: Bool = false) {
        network = WatchLaterNetwork(responseCode: responseCode, holdWrites: holdWrites)
        server = (1...count).map { Self.makeVideo($0) }
    }

    static func makeVideo(_ id: Int) -> Video {
        Video(bvid: "BV_later_\(id)", title: "视频 \(id)", aid: Int64(id))
    }
    func video(_ id: Int) -> Video { Self.makeVideo(id) }

    func loadLibrary() async -> AppModel {
        model.navigate(.watchLater)
        let page = model.browseInstance(for: .watchLater)
        await page.browseTask?.value
        return page
    }

    func waitForHeldRead() async {
        for _ in 0..<100 where heldRead == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(heldRead != nil)
    }
    func resumeRead(_ result: BrowsePageResult) {
        heldRead?.resume(returning: result)
        heldRead = nil
    }
    func waitForWrite() async {
        for _ in 0..<100 where writeCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(writeCount > 0)
    }
    func respondToWrite() { network.respond() }

    func close() {
        network.close()
        if let heldRead { heldRead.resume(returning: BrowsePageResult(videos: [], next: nil)) }
        for page in [model] + Array(model.browseInstances.values)
            + Array(model.playbackInstances.values)
        {
            page.browseTask?.cancel()
            page.toast = nil
            page.playbackTabActive = false
            if let observer = page.observer {
                page.player.removeTimeObserver(observer)
                page.observer = nil
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class WatchLaterNetwork: @unchecked Sendable {
    let api: BilibiliAPI
    private let lock = NSLock()
    private var requests = 0
    private var pending: WatchLaterProtocol?
    var writeCount: Int { lock.withLock { requests } }

    init(responseCode: Int, holdWrites: Bool) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WatchLaterProtocol.self]
        for (name, value) in [
            "SESSDATA": "offline-session", "bili_jct": "offline-csrf", "DedeUserID": "42",
        ] {
            config.httpCookieStorage?.setCookie(
                HTTPCookie(properties: [
                    .name: name, .value: value, .domain: ".bilibili.com", .path: "/",
                    .secure: "TRUE",
                ])!)
        }
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        WatchLaterProtocol.install { [self] client in
            lock.withLock {
                requests += 1
                if holdWrites { pending = client }
            }
            if !holdWrites { client.respond(code: responseCode) }
        }
    }
    func respond() { lock.withLock { pending }?.respond(code: 0) }
    func close() { WatchLaterProtocol.install(nil) }
}

private final class WatchLaterProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((WatchLaterProtocol) -> Void)?
    static func install(_ handler: ((WatchLaterProtocol) -> Void)?) {
        lock.withLock { self.handler = handler }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(self) }
    override func stopLoading() {}
    func respond(code: Int) {
        let data = try! JSONSerialization.data(
            withJSONObject: ["code": code, "message": "mock rejection"])
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
