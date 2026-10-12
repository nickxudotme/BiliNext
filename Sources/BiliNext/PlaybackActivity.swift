import Foundation

/// Each playback tab owns its assertion; buffering preserves it, pausing releases it.
final class PlaybackActivity {
    private var token: NSObjectProtocol?

    func setActive(_ active: Bool) {
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "BiliNext video playback")
        } else if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
