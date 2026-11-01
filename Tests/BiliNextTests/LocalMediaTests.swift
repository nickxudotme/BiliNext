import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

private final class LocalMediaNetworkTrap: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record(
            "Local playback attempted a network request: \(request.url?.host ?? "unknown")")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct LocalMediaTests {
    private func model(_ directory: URL) -> AppModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMediaNetworkTrap.self]
        return AppModel(
            sessionStore: SessionStore(directory: directory),
            downloads: DownloadManager(store: directory.appendingPathComponent("downloads.json")),
            api: BilibiliAPI(restoreSession: false, sessionConfiguration: config),
            browsePageLoader: { _ in BrowsePageResult(videos: [], next: nil) },
            playerFactory: {
                let player = try MPVPlayer(videoOutput: "null")
                player.muted = true
                return player
            })
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(condition())
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func localFilesShareTabsPauseAndRestoreWithoutNetworkOrHistory() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("first.mp4")
        let other = root.appendingPathComponent("second.mp4")
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=96x64:rate=24:duration=6", "-c:v",
            "libx264", file.path,
        ]
        try encoder.run()
        encoder.waitUntilExit()
        #expect(encoder.terminationStatus == 0)
        try FileManager.default.copyItem(at: file, to: other)
        let workspace = model(root)
        workspace.profile = UserProfile(id: 42, name: "test")
        workspace.openLocalMedia(file, title: "缓存视频", autoplay: false)
        let id = try #require(workspace.selected)
        let page = try #require(workspace.playbackInstances[id])
        try await wait { page.mpv?.loaded == true }
        let player = try #require(page.mpv)
        #expect(
            page.isLocalMedia && page.pageID == nil && page.detail == nil && player.flag("pause"))
        #expect(NowPlaying.item(for: workspace)?.title == "缓存视频")
        workspace.openLocalMedia(file, autoplay: false)
        #expect(workspace.tabs.count == 1 && workspace.playbackInstances[id]?.mpv === player)
        page.seek(2)
        try await wait { page.time >= 1.9 }
        page.togglePlayback()
        try await wait { page.time > 2.2 }
        workspace.openLocalMedia(other, autoplay: false)
        #expect(player.flag("pause") && !page.playbackIntent)
        let position = player.time
        workspace.close(id)
        #expect(workspace.playbackInstances[id] == nil)
        workspace.undoClose()
        workspace.activate(id)
        let restored = try #require(workspace.playbackInstances[id])
        try await wait { restored.mpv?.loaded == true }
        #expect(restored.mpv?.flag("pause") == true)
        #expect(abs(restored.time - position) < 0.2)
        workspace.saveSession()
        let restarted = model(root)
        restarted.activate(id)
        let reloaded = try #require(restarted.playbackInstances[id])
        try await wait { reloaded.mpv?.loaded == true }
        #expect(reloaded.mpv?.flag("pause") == true && abs(reloaded.time - position) < 0.2)
        #expect(workspace.historyOutbox.entries.isEmpty)
        await workspace.prepareForTermination()
        await restarted.prepareForTermination()
        #expect(workspace.historyOutbox.entries.isEmpty)
    }

    @Test func legacySessionsAndLocalTrailRemainReadable() throws {
        let old = Data(
            #"[{"video":{"bvid":"BV1234567890","title":"old","author":""},"position":4}]"#.utf8)
        #expect(try JSONDecoder().decode([SessionTab].self, from: old).first?.localMedia == nil)
        let source = try LocalMedia(url: URL(fileURLWithPath: "/tmp/a-video.mp4"))
        let tab = SessionTab(
            video: Video(bvid: source.id, title: "local"), position: 12, localMedia: source)
        var trail = TabTrail()
        trail.leave(tab)
        let entry = try #require(trail.back.first)
        let restored = SessionTab(entry, trail: TabTrail())
        #expect(restored.localMedia == source && restored.position == 12)
        #expect(
            try JSONDecoder().decode(SessionTab.self, from: JSONEncoder().encode(restored))
                == restored)
    }

    @Test func missingFileShowsRecoverableErrorAndRemoteURLNeverCreatesTab() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = model(root)
        workspace.openLocalMedia(URL(string: "https://example.com/video.mp4")!)
        #expect(workspace.tabs.isEmpty && workspace.toast != nil)
        let source = try LocalMedia(url: root.appendingPathComponent("missing.mp4"))
        workspace.tabs = [
            SessionTab(video: Video(bvid: source.id, title: "missing"), localMedia: source)
        ]
        workspace.activate(source.id)
        let page = try #require(workspace.playbackInstances[source.id])
        #expect(page.playerError?.contains("重新选择文件") == true)
        #expect(!page.videoLoading && page.mpv == nil)
        #expect(workspace.tabs.count == 1)
    }
}
