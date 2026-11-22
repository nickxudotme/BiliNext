import SwiftUI

/// Subscribe at the changing overlay, rather than rebuilding the video host and all controls.
struct PlaybackClockView<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder var content: (Double) -> Content

    var body: some View { content(clock.time) }
}
