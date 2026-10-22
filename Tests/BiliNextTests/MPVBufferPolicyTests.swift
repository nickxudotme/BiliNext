import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

// These tests inspect a real mpv handle without rendering or accessing the network.
// The local empty source exercises load setup; decoding it is intentionally unnecessary.
@MainActor
@Test func mpvLiveBufferPolicySurvivesLoadingElapsedTimeAndSpeedChanges() throws {
    let core = try MPVPlayer(videoOutput: "null")
    defer { core.stop() }
    try core.loadLive(URL(fileURLWithPath: "/dev/null"), autoplay: false)

    func expectLivePolicy() {
        #expect(core.number("options/cache-secs") == 5)
        #expect(core.number("options/demuxer-readahead-secs") == 5)
        #expect(core.number("options/cache-pause-wait") == 1)
        #expect(core.number("options/demuxer-max-bytes") == 128 * 1024 * 1024)
    }

    expectLivePolicy()
    core.updateBufferStage(playing: 5)
    expectLivePolicy()
    core.updateBufferStage(playing: 20)
    expectLivePolicy()
    core.speed = 3
    expectLivePolicy()
    core.speed = 0.5
    expectLivePolicy()
}

@MainActor
@Test func mpvSwitchingBetweenLiveAndVideoResetsBufferPolicy() throws {
    let core = try MPVPlayer(videoOutput: "null")
    defer { core.stop() }
    let source = URL(fileURLWithPath: "/dev/null")
    let video = Playback(
        url: source, quality: "1080P", qualityID: 80, qualities: [], videoStream: nil,
        audioStream: nil)

    core.speed = 3
    core.updateBufferStage(playing: 20)
    #expect(core.number("options/cache-secs") == 210)
    try core.loadLive(source, autoplay: false)
    #expect(core.number("options/cache-secs") == 5)
    #expect(core.number("options/demuxer-readahead-secs") == 5)
    #expect(core.number("options/cache-pause-wait") == 1)
    #expect(core.number("options/demuxer-max-bytes") == 128 * 1024 * 1024)

    try core.load(video, position: 0, autoplay: false)
    #expect(core.number("options/cache-secs") == 60)
    #expect(core.number("options/demuxer-readahead-secs") == 60)
    #expect(core.number("options/cache-pause-wait") == 9)
    #expect(core.number("options/demuxer-max-bytes") == 256 * 1024 * 1024)
    core.updateBufferStage(playing: 5)
    #expect(core.number("options/cache-secs") == 120)
    core.updateBufferStage(playing: 20)
    #expect(core.number("options/cache-secs") == 210)
    core.speed = 0.5
    #expect(core.number("options/cache-secs") == 70)
    #expect(core.number("options/cache-pause-wait") == 3)
}
