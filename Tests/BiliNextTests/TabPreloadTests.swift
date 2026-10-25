import Combine
import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func pausedNetworkPreloadDecodesAndBuffersBeforePlayback() async throws {
    let api = BilibiliAPI(restoreSession: false)
    let detail = try await api.detail("BV1vypR63EiD")
    let page = try #require(detail.pages.first)
    let source = try await api.playback(bvid: detail.video.bvid, cid: page.cid)
    let core = try MPVPlayer(videoOutput: "null")
    core.isForeground = false
    core.muted = true
    defer { core.stop() }
    try core.load(source, position: 0, autoplay: false)
    for _ in 0..<100 {
        if core.failure != nil
            || (core.loaded && core.number("video-params/w") > 0
                && core.number("demuxer-cache-duration") >= 10)
        {
            break
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    #expect(core.failure == nil && core.loaded)
    #expect(core.number("video-params/w") > 0)
    #expect(core.number("demuxer-cache-duration") >= 10)
    #expect(core.flag("pause") && !core.playing && core.time < 0.5)
    #expect(core.pollInterval == 1)
    print(
        "Paused preload: width=\(core.number("video-params/w")), buffered=\(core.number("demuxer-cache-duration"))s, time=\(core.time)"
    )
    print(
        "Paused network cache: end=\(core.number("demuxer-cache-time")), eof-cached=\(core.cacheSnapshot?.eof == true), video-end=\(core.cacheSnapshot?.videoEnd ?? -1)"
    )
    core.isForeground = true
    core.play()
    for _ in 0..<30 where core.time < 0.5 {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(core.playing && core.time >= 0.5)
}

@MainActor
@Suite(.serialized)
struct TabPreloadTests {
    @Test(arguments: [false, true])
    func tabSelectionUsesAutoplaySettingWithoutReloading(autoplay: Bool) async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        var overrides = saved
        overrides[Preferences.autoplayOnTabSelection] = autoplay
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        let fixture = try TabPreloadFixture(count: 2)
        defer { fixture.close() }
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        let first = fixture.workspace.tabs[0].id
        let second = fixture.workspace.tabs[1].id
        let page = try #require(fixture.workspace.playbackInstances[first])
        let core = try #require(page.mpv)
        fixture.workspace.selectTab(first)  // Sidebar selection uses this same entry point.
        try await fixture.waitUntil { page.playing == autoplay }
        #expect(page.playbackIntent == autoplay && core.flag("pause") == !autoplay)
        #expect(fixture.workspace.playbackInstances[first]?.mpv === core)
        fixture.workspace.activateTab(number: 2)
        let other = try #require(fixture.workspace.playbackInstances[second])
        try await fixture.waitUntil { other.playing == autoplay }
        #expect(!page.playbackIntent && core.flag("pause"))
        fixture.workspace.cycleTab(-1)
        try await fixture.waitUntil { page.playing == autoplay }
        #expect(fixture.workspace.selected == first)
        #expect(fixture.workspace.playbackInstances[first]?.mpv === core)
        #expect(fixture.playbackRequests.count == 2)
        if !autoplay { #expect(fixture.historyReports.isEmpty) }
    }

    @Test func idlePreloadsStopPublishingAndAreNotSuspendedAgain() async throws {
        let fixture = try TabPreloadFixture(count: 3)
        defer { fixture.close() }
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        let page = try #require(fixture.workspace.playbackInstances[fixture.workspace.tabs[2].id])
        let core = try #require(page.mpv)
        #expect(core.pollInterval == 1 && !core.isForeground)
        var updates = 0
        let subscription = page.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        fixture.workspace.activate(fixture.workspace.tabs[0].id)
        fixture.workspace.activate(fixture.workspace.tabs[1].id)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(updates == 0)
        fixture.workspace.activate(fixture.workspace.tabs[2].id)
        #expect(core.isForeground && core.pollInterval == 0.25)
        #expect(core.loaded && core.flag("pause") && !page.playbackIntent)
        // Foreground callbacks must still persist a paused seek periodically.
        page.lastSaved = Date()
        page.seek(8)
        try await fixture.waitUntil { abs(page.time - 8) < 0.1 }
        page.lastSaved = .distantPast
        try await fixture.waitUntil { page.lastSaved != .distantPast }
        let saved = try fixture.workspace.sessionStore.read().first { $0.id == page.mediaID }
        #expect(abs((saved?.position ?? 0) - 8) < 0.1)
    }

    @Test func newBackgroundTabAndUndoLoadWithoutChangingTheForegroundTab() async throws {
        let fixture = try TabPreloadFixture(count: 1)
        defer { fixture.close() }
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        let first = fixture.workspace.tabs[0]
        fixture.workspace.activate(first.id)
        let foreground = fixture.workspace.playbackInstances[first.id]?.mpv
        let video = Video(bvid: "BV0000000002", title: "新后台视频")
        fixture.workspace.open(video, background: true)
        let background = try #require(fixture.workspace.playbackInstances[video.id])
        fixture.configure(background)
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        let loadedPlayer = try #require(background.mpv)
        #expect(loadedPlayer.loaded && !loadedPlayer.playing)
        #expect(background.commentListState?.loader.page == 1)
        #expect(fixture.workspace.selected == first.id)
        #expect(fixture.workspace.playbackInstances[first.id]?.mpv === foreground)
        #expect(fixture.workspace.unseenTabs.contains(video.id))
        fixture.workspace.close(video.id)
        fixture.workspace.undoClose()
        let restored = try #require(fixture.workspace.playbackInstances[video.id])
        fixture.configure(restored)
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        #expect(restored !== background && restored.mpv !== loadedPlayer)
        #expect(restored.mpv?.loaded == true && restored.mpv?.flag("pause") == true)
        #expect(fixture.workspace.selected == first.id && fixture.historyReports.isEmpty)
    }

    @Test func startupLoadsEveryRestoredTabAndCommentsWithoutPlayingOrReporting() async throws {
        let fixture = try TabPreloadFixture(count: 3)
        defer { fixture.close() }
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        #expect(fixture.workspace.selected == nil)
        #expect(fixture.workspace.playbackInstances.count == 3)
        for tab in fixture.workspace.tabs {
            let page = try #require(fixture.workspace.playbackInstances[tab.id])
            #expect(page.detail?.video.bvid == tab.id && page.pageID == tab.cid)
            #expect(page.mpv?.loaded == true && page.mpv?.flag("pause") == true)
            #expect((page.mpv?.number("video-params/w") ?? 0) > 0)
            #expect(abs(page.time - 5) < 0.5)
            #expect(!page.playing && !page.playbackTabActive && !page.playbackIntent)
            #expect(page.commentListState?.loader.page == 1)
            #expect(page.commentListState?.loader.comments.first?.text == "已预加载的评论")
            #expect(fixture.count(path: "/x/web-interface/view/detail", bvid: tab.id) == 1)
        }
        #expect(fixture.playbackRequests.count == 3)
        #expect(fixture.historyReports.isEmpty && fixture.workspace.historyOutbox.entries.isEmpty)
        await fixture.workspace.prepareForTermination(timeout: 0)
        #expect(fixture.historyReports.isEmpty)
    }

    @Test(arguments: [true, false], [true, false])
    func activationDuringPreloadKeepsTheLatestPlaybackIntent(stayActive: Bool, autoplay: Bool)
        async throws
    {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        var overrides = saved
        overrides[Preferences.autoplayOnTabSelection] = autoplay
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        let fixture = try TabPreloadFixture(count: 1)
        defer { fixture.close() }
        let tab = fixture.workspace.tabs[0]
        fixture.blockDetails(tab.id)
        await fixture.workspace.start()
        try await fixture.waitUntil {
            fixture.count(path: "/x/web-interface/view/detail", bvid: tab.id) == 1
        }
        let page = try #require(fixture.workspace.playbackInstances[tab.id])
        fixture.workspace.selectTab(tab.id)
        if !stayActive { fixture.workspace.navigate(.home) }
        fixture.releaseDetails(tab.id)
        try await fixture.waitUntil { page.mpv?.loaded == true && !page.videoLoading }
        #expect(fixture.workspace.playbackInstances[tab.id] === page)
        #expect(page.playbackIntent == (stayActive && autoplay))
        #expect(page.mpv?.flag("pause") == !(stayActive && autoplay))
        #expect(fixture.count(path: "/x/web-interface/view/detail", bvid: tab.id) == 1)
        #expect(fixture.playbackRequests.count == 1)
        if !stayActive || !autoplay { #expect(fixture.historyReports.isEmpty) }
    }

    @Test func closingLoadingAndQueuedTabsCancelsTheirWorkAndAdvancesTheQueue() async throws {
        let fixture = try TabPreloadFixture(count: 4)
        defer { fixture.close() }
        let tabs = fixture.workspace.tabs
        fixture.blockDetails(tabs[0].id)
        fixture.blockDetails(tabs[1].id)
        await fixture.workspace.start()
        try await fixture.waitUntil {
            fixture.count(path: "/x/web-interface/view/detail") == AppModel.tabPreloadConcurrency
        }
        #expect(fixture.workspace.tabPreloadJobs.count == 2)
        #expect(fixture.count(path: "/x/web-interface/view/detail", bvid: tabs[2].id) == 0)
        fixture.workspace.close(tabs[2].id)
        fixture.workspace.close(tabs[0].id)
        fixture.releaseDetails(tabs[0].id)
        fixture.releaseDetails(tabs[1].id)
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        #expect(fixture.workspace.playbackInstances[tabs[0].id] == nil)
        #expect(fixture.workspace.playbackInstances[tabs[2].id] == nil)
        #expect(fixture.count(path: "/x/web-interface/view/detail", bvid: tabs[2].id) == 0)
        #expect(fixture.workspace.playbackInstances[tabs[3].id]?.mpv?.loaded == true)
        #expect(fixture.historyReports.isEmpty)
    }

    @Test(arguments: [false, true])
    func accountChangePreservesCurrentPlaybackProgress(loggingOut: Bool) async throws {
        let fixture = try TabPreloadFixture(count: 1)
        defer { fixture.close() }
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        let id = fixture.workspace.tabs[0].id
        fixture.workspace.activate(id)
        let previous = try #require(fixture.workspace.playbackInstances[id])
        previous.seek(12)
        try await fixture.waitUntil { abs((previous.mpv?.time ?? 0) - 12) < 0.2 }
        fixture.workspace.saveSession(updateTabs: false)
        #expect(abs((try fixture.workspace.sessionStore.read().first?.position ?? 0) - 12) < 0.2)
        if loggingOut {
            await fixture.workspace.logout()
        } else {
            await fixture.workspace.loggedIn()
        }
        let current = try #require(fixture.workspace.playbackInstances[id])
        fixture.configure(current)
        try await fixture.waitUntil { current.mpv?.loaded == true && !current.videoLoading }
        #expect(current !== previous)
        #expect(abs((current.mpv?.time ?? 0) - 12) < 0.2)
        #expect(current.pageID == 12 && current.mpv?.flag("pause") == true)
        #expect(fixture.historyReports.isEmpty)
    }

    @Test(arguments: ["all", "clearOthers", "others", "below"])
    func batchCloseDoesNotStartQueuedTabsBeingClosed(operation: String) async throws {
        let fixture = try TabPreloadFixture(count: 6)
        defer { fixture.close() }
        let tabs = fixture.workspace.tabs
        fixture.blockDetails(tabs[0].id)
        fixture.blockDetails(tabs[1].id)
        await fixture.workspace.start()
        try await fixture.waitUntil { fixture.playbackRequests.count == 2 }
        switch operation {
        case "clearOthers":
            fixture.workspace.activate(tabs[0].id)
            fixture.workspace.clearTabs()
        case "others": fixture.workspace.closeOtherTabs(keeping: tabs[3].id)
        case "below": fixture.workspace.closeOtherTabs(keeping: tabs[0].id, onlyBelow: true)
        default: fixture.workspace.clearTabs()
        }
        let remaining = Set(fixture.workspace.tabs.map(\.id))
        fixture.releaseDetails(tabs[0].id)
        fixture.releaseDetails(tabs[1].id)
        // Let independently warmed playurl tasks run even if closing emptied the queue.
        try await Task.sleep(for: .milliseconds(300))
        try await fixture.waitUntil { fixture.workspace.tabPreloadJobs.isEmpty }
        // Early playurl requests for the two initial jobs are legitimate. None of
        // the closed queued tabs may start one while that batch is being released.
        let allowed = remaining.union(tabs.prefix(2).map(\.id))
        #expect(fixture.playbackRequests.allSatisfy { allowed.contains($0.bvid) })
        #expect(fixture.playbackRequests.count == (operation == "others" ? 3 : 2))
        #expect(Set(fixture.workspace.closed.map(\.id)).isDisjoint(with: remaining))
        for id in remaining {
            #expect(fixture.workspace.playbackInstances[id]?.mpv?.loaded == true)
        }
        #expect(fixture.historyReports.isEmpty)
    }

    @Test func loginReplacesOldAccountPreloadsAndIgnoresTheirLateResponses() async throws {
        let fixture = try TabPreloadFixture(count: 1)
        defer { fixture.close() }
        let tab = fixture.workspace.tabs[0]
        fixture.blockDetails(tab.id)
        await fixture.workspace.start()
        try await fixture.waitUntil {
            fixture.count(path: "/x/web-interface/view/detail", bvid: tab.id) == 1
        }
        let previous = try #require(fixture.workspace.playbackInstances[tab.id])
        let account = fixture.workspace.accountGeneration
        await fixture.workspace.loggedIn()
        let current = try #require(fixture.workspace.playbackInstances[tab.id])
        fixture.configure(current)
        #expect(current !== previous && current.accountGeneration != account)
        fixture.releaseDetails(tab.id)
        try await fixture.waitUntil { current.mpv?.loaded == true && !current.videoLoading }
        #expect(previous.detail == nil && previous.mediaID == nil)
        #expect(current.commentListState?.context?.accountGeneration == current.accountGeneration)
        #expect(fixture.historyReports.isEmpty)
    }
}

private final class TabPreloadFixture: @unchecked Sendable {
    let directory: URL
    let media: URL
    let lock = NSLock()
    private var requests: [URLRequest] = []
    private var blocked: Set<String> = []
    private var pending: [String: [TabPreloadProtocol]] = [:]
    @MainActor var workspace: AppModel!
    @MainActor var playbackRequests: [PlaybackPrefetch.Key] = []
    @MainActor var historyReports: [WatchHistoryReporter.Progress] = []

    @MainActor init(count: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        media = directory.appendingPathComponent("preload.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10", "-t", "20",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", media.path,
        ]
        try encoder.run()
        encoder.waitUntilExit()
        #expect(encoder.terminationStatus == 0)
        let store = SessionStore(directory: directory)
        try store.write(
            (1...count).map {
                SessionTab(
                    video: Video(bvid: String(format: "BV%010d", $0), title: "视频 \($0)"),
                    cid: Int64($0 * 10 + 2), position: 5)
            })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TabPreloadProtocol.self]
        let api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        workspace = AppModel(
            sessionStore: store, api: api,
            browsePageLoader: { _ in BrowsePageResult(videos: [], next: nil) },
            profileLoader: { UserProfile(id: 7, name: "离线测试") },
            favoriteFolderLoader: { _ in [] },
            playerFactory: { try MPVPlayer(videoOutput: "null") })
        workspace.services.playbackPrefetch = PlaybackPrefetch { [weak self] key in
            guard let self else { throw CancellationError() }
            playbackRequests.append(key)
            return Playback(
                url: media, quality: "测试", qualityID: key.quality, qualities: [],
                videoStream: nil, audioStream: nil)
        }
        for tab in workspace.tabs { configure(workspace.playbackInstance(for: tab)) }
        TabPreloadProtocol.handler = { [weak self] connection in self?.respond(connection) }
    }

    @MainActor func configure(_ page: AppModel) {
        page.player.isMuted = true
        page.watchHistoryReporter = WatchHistoryReporter(
            send: { [weak self] in self?.historyReports.append($0) }, onError: { _ in },
            account: { 7 })
    }

    func count(path: String, bvid: String? = nil) -> Int {
        lock.withLock {
            requests.filter {
                $0.url?.path == path && (bvid == nil || Self.query($0)["bvid"] == bvid)
            }.count
        }
    }

    func blockDetails(_ id: String) { _ = lock.withLock { blocked.insert(id) } }

    func releaseDetails(_ id: String) {
        let connections = lock.withLock {
            blocked.remove(id)
            return pending.removeValue(forKey: id) ?? []
        }
        for connection in connections { respond(connection, released: true) }
    }

    @MainActor func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "后台标签未在超时前完成预加载")
    }

    @MainActor func close() {
        workspace.cancelAllTabPreloads()
        workspace.selected = nil
        workspace.clearTabs()
        for id in lock.withLock({ Array(pending.keys) }) { releaseDetails(id) }
        TabPreloadProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func respond(_ connection: TabPreloadProtocol, released: Bool = false) {
        let request = connection.request
        let path = request.url!.path
        let query = Self.query(request)
        let bvid = query["bvid"] ?? ""
        let held = lock.withLock {
            if !released { requests.append(request) }
            if path == "/x/web-interface/view/detail", blocked.contains(bvid), !released {
                pending[bvid, default: []].append(connection)
                return true
            }
            return false
        }
        if held { return }
        let data: [String: Any]
        switch path {
        case "/x/web-interface/view/detail":
            let number = Int(bvid.dropFirst(2)) ?? 1
            data = [
                "View": [
                    "bvid": bvid, "aid": number, "title": "视频 \(number)",
                    "pages": [
                        ["cid": number * 10 + 1, "page": 1, "part": "第一 P", "duration": 20],
                        ["cid": number * 10 + 2, "page": 2, "part": "恢复的分 P", "duration": 20],
                    ],
                ]
            ]
        case "/x/web-interface/nav":
            data = [
                "isLogin": true, "mid": 7, "uname": "离线测试",
                "wbi_img": [
                    "img_url": "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                    "sub_url": "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png",
                ],
            ]
        case "/x/v2/reply":
            data = [
                "page": ["count": 1],
                "replies": [
                    [
                        "rpid": 1, "content": ["message": "已预加载的评论"],
                        "member": ["uname": "测试用户", "mid": 8],
                    ]
                ],
            ]
        default: data = [:]
        }
        connection.respond(["code": 0, "data": data])
    }
}

private final class TabPreloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((TabPreloadProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(_ body: [String: Any]) {
        guard let client else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client.urlProtocolDidFinishLoading(self)
    }
}
