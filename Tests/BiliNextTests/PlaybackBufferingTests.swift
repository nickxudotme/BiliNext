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
