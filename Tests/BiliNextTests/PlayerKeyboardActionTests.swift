import BiliNextCore
import Combine
import Foundation
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
private func drainKeyboardActions() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
private func keyboardModel() -> AppModel {
    AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        managesPlaybackTabs: false, api: BilibiliAPI(restoreSession: false),
        subtitlePreferences: UserDefaults(suiteName: UUID().uuidString)!)
}

@MainActor
@Suite struct PlayerKeyboardActionTests {
    @Test func playbackAndSeekPublishOnlyAfterKeyboardCallbackReturns() async {
        let model = keyboardModel()
        defer { model.stopMedia() }
        var publicationsDuringCallback = 0
        var inCallback = true
        let playback = model.objectWillChange.sink {
            if inCallback { publicationsDuringCallback += 1 }
        }
        let subtitles = model.smartSubtitles.objectWillChange.sink {
            if inCallback { publicationsDuringCallback += 1 }
        }
        var executed: [String] = []
        let result = PlayerKeyboardAction.enqueue(model: model) {
            model.togglePlayback()
            executed.append("toggle")
        }
        _ = PlayerKeyboardAction.enqueue(model: model) {
            model.seek(10)
            executed.append("seek")
        }
        #expect(result == .handled)
        #expect(executed.isEmpty && publicationsDuringCallback == 0)
        inCallback = false
        await drainKeyboardActions()
        #expect(executed == ["toggle", "seek"])
        #expect(publicationsDuringCallback == 0)
        withExtendedLifetime((playback, subtitles)) {}
    }

    @Test func queuedKeyPhasesKeepTheirOrderAndRestoreTemporarySpeed() async {
        let model = keyboardModel()
        defer { model.stopMedia() }
        model.setRate(1.25)
        var phases: [String] = []
        var previousRate: Double?
        _ = PlayerKeyboardAction.enqueue(model: model) { phases.append("down") }
        _ = PlayerKeyboardAction.enqueue(model: model) {
            phases.append("repeat")
            previousRate = model.playbackRate
            model.setRate(3)
        }
        _ = PlayerKeyboardAction.enqueue(model: model) {
            phases.append("up")
            if let previousRate { model.setRate(previousRate) }
        }
        #expect(phases.isEmpty && model.playbackRate == 1.25)
        await drainKeyboardActions()
        #expect(phases == ["down", "repeat", "up"])
        #expect(model.playbackRate == 1.25)
    }

    @Test func queuedActionsCannotAffectAnInactiveTabOrReplacedVideo() async {
        let model = keyboardModel()
        defer { model.stopMedia() }
        var actions = 0
        _ = PlayerKeyboardAction.enqueue(model: model) { actions += 1 }
        model.playbackTabActive = false
        await drainKeyboardActions()
        #expect(actions == 0)
        #expect(PlayerKeyboardAction.enqueue(model: model) { actions += 1 } == .ignored)
        model.playbackTabActive = true
        _ = PlayerKeyboardAction.enqueue(model: model) { actions += 1 }
        model.videoGeneration = UUID()
        await drainKeyboardActions()
        #expect(actions == 0)
    }
}
