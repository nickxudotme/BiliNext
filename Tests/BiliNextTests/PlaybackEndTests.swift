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
}
