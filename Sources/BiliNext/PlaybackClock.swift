import Combine
import Foundation

/// Only time-dependent views subscribe; the app shell and comments never receive timer ticks.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var time = 0.0
    func update(_ value: Double) {
        let next = value.isFinite ? max(0, value) : 0
        guard next != time else { return }
        time = next
    }
}
