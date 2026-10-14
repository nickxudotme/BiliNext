import AVFoundation
import AppKit
import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func playbackTabSwitchRetainsLoadedMedia() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let first = SessionTab(video: Video(bvid: "BV1p1n8zdEAk", title: "4K 风景"))
    let second = SessionTab(video: Video(bvid: "BV1dyaZ6gEwU", title: "科普视频"))
    workspace.tabs = [first, second]
    let a = workspace.playbackInstance(for: first)
    let b = workspace.playbackInstance(for: second)
    a.player.isMuted = true
    b.player.isMuted = true
    defer {
        workspace.selected = nil
        workspace.clearTabs()
    }
    var surfaces: [String: MPVSurface.Surface] = [:]
    func waitForPlayback(_ page: AppModel) async throws {
        for _ in 0..<200 {
            if let core = page.mpv, surfaces[page.selected ?? ""] == nil {
                let surface = try #require(MPVSurface.Surface(player: core))
                surface.setFrameSize(NSSize(width: 640, height: 360))
                surfaces[page.selected ?? ""] = surface
            }
            surfaces[page.selected ?? ""]?.video.display()
            if page.playerError != nil || (page.mpv?.time ?? 0) > 1 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(page.playerError == nil)
        #expect(page.mpv?.loaded == true)
        #expect((page.mpv?.time ?? 0) > 1)
    }
    workspace.activate(first.id, autoplay: true)
    try await waitForPlayback(a)
    let item = try #require(a.mpv)
    a.setRate(1.5)
    a.seek(30)
    try await Task.sleep(for: .seconds(1))
    workspace.activate(second.id, autoplay: true)
    let position = a.mpv?.time ?? 0
    try await waitForPlayback(b)
    #expect(a.mpv?.playing == false)
    #expect(a.mpv === item)
    #expect(abs((a.mpv?.time ?? 0) - position) < 0.5)
    workspace.activate(first.id, autoplay: true)
    #expect(a.mpv === item)
    #expect(a.playbackRate == 1.5)
    #expect(b.mpv?.playing == false)
    #expect(workspace.playbackInstances.count == 2)
    a.togglePlayback()
    let savedPosition = a.mpv?.time ?? 0
    a.selectQuality(64)
    for _ in 0..<200 {
        surfaces[first.id]?.draw(.zero)
        if !a.videoLoading { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(a.playerError == nil)
    #expect(a.qualityID == 64)
    #expect(a.mpv === item)
    #expect(a.mpv?.playing == false)
    #expect(abs((a.mpv?.time ?? 0) - savedPosition) < 1)
    a.selectQuality(80)
    a.selectQuality(64)
    for _ in 0..<200 {
        surfaces[first.id]?.draw(.zero)
        if !a.videoLoading { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(a.qualityID == 64)
    #expect(a.playerError == nil)

    workspace.close(second.id)
    #expect(workspace.playbackInstances.count == 1)
    #expect(a.mpv === item)
    if ProcessInfo.processInfo.environment["BILINEXT_MPV_4K_TEST"] == "1" {
        a.selectQuality(120)
        for _ in 0..<200 {
            surfaces[first.id]?.draw(.zero)
            if !a.videoLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(a.playerError == nil)
        #expect(a.qualityID == 120)
        a.togglePlayback()
        for _ in 0..<100 {
            surfaces[first.id]?.draw(.zero)
            if (a.mpv?.number("video-params/w") ?? 0) >= 3840
                && a.mpv?.text("hwdec-current") == "videotoolbox"
            {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect((a.mpv?.number("video-params/w") ?? 0) >= 3840)
        #expect(a.mpv?.text("hwdec-current") == "videotoolbox")
        print(
            "MPV 4K: \(a.playbackCodec), width=\(a.mpv?.number("video-params/w") ?? 0), hardware=\(a.mpv?.text("hwdec-current") ?? "")"
        )
    }
    print(
        "Persistent tabs: two muted players, same loaded item and position retained, inactive page paused, close released only its player"
    )
}

@MainActor
@Test func browsingPagesKeepIndependentStateWhenRevisited() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let home = workspace.browseInstance(for: .home)
    let dynamic = workspace.browseInstance(for: .dynamic)
    let search = workspace.browseInstance(for: .search)
    home.homeSection = "热门"
    home.videos = [Video(bvid: "BV1111111111", title: "保留的内容")]
    dynamic.dynamicMode = "全部"
    search.query = "4K 风景"
    workspace.navigate(.home)
    workspace.navigate(.dynamic)
    workspace.moveHistory(-1)
    #expect(workspace.menu == .home)
    #expect(workspace.browseInstance(for: .home) === home)
    #expect(home.homeSection == "热门" && home.videos.count == 1)
    #expect(dynamic.dynamicMode == "全部")
    #expect(search.query == "4K 风景")
    search.toast = "页面消息"
    #expect(workspace.toast == "页面消息")
    search.loginPresented = true
    #expect(workspace.loginPresented)
}

@MainActor
@Test func playbackPagesKeepPlayersAndReleaseClosedTabs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = AppModel(sessionStore: SessionStore(directory: directory))
    let first = SessionTab(video: Video(bvid: "BV1111111111", title: "一"))
    let second = SessionTab(video: Video(bvid: "BV2222222222", title: "二"))
    workspace.tabs = [first, second]
    let a = workspace.playbackInstance(for: first)
    let b = workspace.playbackInstance(for: second)
    #expect(a.player !== b.player)
    #expect(a.danmaku !== b.danmaku)
    #expect(a.playbackClock !== b.playbackClock)
    a.qualityID = 120
    a.playbackRate = 1.5
    a.theater = true
    a.pageID = 42
    a.officialCore = true
    a.time = 123
    b.pageID = 43
    b.officialCore = true
    b.time = 456
    workspace.saveSession()
    let saved = try SessionStore(directory: directory).read()
    #expect(saved[0].position == 123 && saved[0].cid == 42)
    #expect(saved[1].position == 456 && saved[1].cid == 43)
    #expect(workspace.playbackInstance(for: first) === a)
    #expect(a.qualityID == 120 && a.playbackRate == 1.5 && a.theater)
    workspace.close(second.id)
    #expect(workspace.playbackInstances[second.id] == nil)
    #expect(workspace.playbackInstances[first.id] === a)
    workspace.undoClose()
    #expect(workspace.tabs.count == 2)
    #expect(workspace.playbackInstances[second.id] == nil)
    workspace.clearTabs()
    #expect(workspace.playbackInstances.isEmpty)
}
