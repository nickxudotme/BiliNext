import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var snapshot = PerformanceSamples.Snapshot()
    private var samples = PerformanceSamples()
    private var lastPublish = 0.0

    func reset() {
        samples.reset()
        lastPublish = 0
    }

    func tick(_ link: CADisplayLink, screenMaximum: Int) {
        let now = CACurrentMediaTime()
        samples.record(
            time: now, budget: link.targetTimestamp - link.timestamp, target: link.targetTimestamp)
        guard now - lastPublish >= 0.5 else { return }
        lastPublish = now
        snapshot = samples.snapshot(screenMaximum: screenMaximum)
    }
}
