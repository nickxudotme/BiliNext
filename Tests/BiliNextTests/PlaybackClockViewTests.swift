import AppKit
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Test func playbackClockUpdatesOnlyItsSubscribedSubtree() async throws {
    _ = NSApplication.shared
    final class Counts {
        var parent = 0
        var child = 0
        var time = 0.0
    }
    struct Parent: View {
        let clock: PlaybackClock
        let counts: Counts
        var body: some View {
            counts.parent += 1
            return PlaybackClockView(clock: clock) { time in
                counts.child += 1
                counts.time = time
                return Text("\(time)")
            }
        }
    }
    let clock = PlaybackClock()
    let counts = Counts()
    let host = NSHostingView(rootView: Parent(clock: clock, counts: counts))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let parent = counts.parent
    let child = counts.child
    #expect(parent > 0 && child > 0)
    clock.update(12)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(counts.parent == parent)
    #expect(counts.child > child)
    #expect(counts.time == 12)
    withExtendedLifetime(host) {}
}
