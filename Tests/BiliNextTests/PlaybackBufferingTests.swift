import AVFoundation
import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func playbackUsesBufferingWithoutLosingRequestedSpeed() {
    let model = AppModel(managesPlaybackTabs: false, api: BilibiliAPI(restoreSession: false))
    model.setRate(1.5)
    model.startBufferedPlayback()
    #expect(model.player.automaticallyWaitsToMinimizeStalling)
    #expect(model.player.defaultRate == 1.5)
    model.player.pause()
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_SUSTAINED_TEST"] == "1"))
func sustainedMutedPlaybackCrossesMultipleFragments() async throws {
    let model = AppModel(managesPlaybackTabs: false)
    model.player.isMuted = true
    let video = Video(bvid: "BV1DApx61EcR", title: "持续播放测试")
    model.tabs = [SessionTab(video: video)]
    defer {
        model.player.pause()
        model.player.replaceCurrentItem(with: nil)
    }
    model.activate(video.id, autoplay: true)
    for _ in 0..<300 {
        if model.playerError != nil || model.player.currentTime().seconds >= 45 { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(model.playerError == nil)
    #expect(model.player.currentItem?.status == .readyToPlay)
    #expect(model.player.currentTime().seconds >= 45)
    #expect(model.player.isMuted)
    model.togglePlayback()
    #expect(model.player.timeControlStatus == .paused)
}
