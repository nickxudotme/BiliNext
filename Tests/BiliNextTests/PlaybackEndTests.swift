import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@Test func nextPartThenNextEpisodeAcrossSections() {
    let pages = [
        VideoPage(cid: 1, number: 1, title: "上"), VideoPage(cid: 2, number: 2, title: "下"),
    ]
    #expect(AppModel.nextPage(after: 1, in: pages)?.cid == 2)
    #expect(AppModel.nextPage(after: 2, in: pages) == nil)
    #expect(AppModel.nextPage(after: nil, in: pages) == nil)

    func episode(_ bvid: String) -> VideoSeason.Episode {
        VideoSeason.Episode(
            bvid: bvid, aid: 1, cid: 9, title: bvid, cover: nil, duration: 60, views: nil,
            pubdate: nil, author: "UP")
    }
    let season = VideoSeason(
        id: 1, title: "合集", cover: nil, views: nil,
        sections: [
            .init(id: 1, title: "正片", episodes: [episode("BV1"), episode("BV2")]),
            .init(id: 2, title: "番外", episodes: [episode("BV3")]),
        ])
    #expect(AppModel.nextEpisode(after: "BV1", in: season)?.bvid == "BV2")
    // Sections continue into each other.
    let crossing = AppModel.nextEpisode(after: "BV2", in: season)
    #expect(crossing?.bvid == "BV3" && crossing?.cid == 9 && crossing?.author == "UP")
    #expect(AppModel.nextEpisode(after: "BV3", in: season) == nil)
    #expect(AppModel.nextEpisode(after: "BV9", in: season) == nil)
    #expect(AppModel.nextEpisode(after: "BV1", in: nil) == nil)
}

@Suite(.serialized)
struct PlaybackEndPreferenceTests {
    @Test func endActionDefaultsToContinuingParts() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Preferences.endActionKey)
        defer { defaults.set(saved, forKey: Preferences.endActionKey) }
        defaults.removeObject(forKey: Preferences.endActionKey)
        #expect(Preferences.endAction == .next)
        defaults.set("loop", forKey: Preferences.endActionKey)
        #expect(Preferences.endAction == .loop)
    }

    @MainActor
    @Test func completingPlaybackLetsTheFirstPlayClickResume() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Preferences.endActionKey)
        defer { defaults.set(saved, forKey: Preferences.endActionKey) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = AppModel(
            sessionStore: SessionStore(directory: directory), managesPlaybackTabs: false,
            api: BilibiliAPI(restoreSession: false))
        let video = Video(bvid: "BV1111111111", title: "最后一集")
        page.selected = video.id
        page.mediaID = video.id
        page.pageID = 1
        page.detail = VideoDetail(
            video: video, pages: [VideoPage(cid: 1, number: 1, title: "正片")], description: "")
        page.mpv = try MPVPlayer(videoOutput: "null")
        defer { page.stopMedia() }

        for action in [PlaybackEndAction.pause, .next, .nextOrRelated] {
            defaults.set(action.rawValue, forKey: Preferences.endActionKey)
            // The EOF callback has updated playing, but its original intent was to play.
            page.playing = false
            page.playbackIntent = true
            page.playbackEnded()
            #expect(!page.playbackIntent)
            page.togglePlayback()
            #expect(page.playbackIntent && page.playing)
        }
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func mpvReportsTheEndOfPlayback() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=1.5",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", folder.appendingPathComponent("end.mp4").path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    let core = try MPVPlayer(videoOutput: "null")
    defer { core.stop() }
    var ended = 0
    core.onUpdate = { _, _, _, _ in if core.ended { ended += 1 } }
    try core.load(
        Playback(
            url: folder.appendingPathComponent("end.mp4"), quality: "test", qualityID: 80,
            qualities: [], videoStream: nil, audioStream: nil),
        position: 0, autoplay: true)
    for _ in 0..<40 where ended == 0 { try await Task.sleep(for: .milliseconds(150)) }
    #expect(ended > 0 && !core.playing)
    // keep-open holds EOF; play must seek back and then advance from the start.
    core.play()
    for _ in 0..<20 where core.ended || core.time < 0.1 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(core.playing && !core.ended)
    #expect(core.time >= 0.1 && core.time < 1.25)
}
