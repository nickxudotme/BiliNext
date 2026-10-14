import Foundation
import os

/// Times one video's startup, from opening its tab to the first advancing frame.
///
/// Each startup is an `OSSignposter` interval with an event per stage, for Instruments, and
/// ends with one persisted log line summarising every stage, so slow starts can be analysed
/// later from the system log:
///
///     log show --last 1d --predicate 'category == "PlaybackStartup"'
///
/// The subsystem is the bundle identifier, so Debug test bundles log under their own.
@MainActor
final class PlaybackStartup {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "me.nickxu.BiliNext"
    private static let logger = Logger(subsystem: subsystem, category: "PlaybackStartup")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "PlaybackStartup")

    let videoID: String
    let autoplay: Bool
    /// Where playback starts; the first frame is the first time past it.
    var position: Double
    private let clock = ContinuousClock()
    private let begin: ContinuousClock.Instant
    private let signpost: OSSignpostID
    private let interval: OSSignpostIntervalState
    private var stages: [(name: String, at: Duration, detail: String)] = []
    private(set) var finished = false

    init(videoID: String, position: Double, autoplay: Bool) {
        self.videoID = videoID
        self.position = position
        self.autoplay = autoplay
        begin = clock.now
        signpost = Self.signposter.makeSignpostID()
        interval = Self.signposter.beginInterval(
            "Startup", id: signpost, "\(videoID, privacy: .public)")
    }

    /// Records a stage, such as `detail` or `playurl`, with optional context.
    func mark(_ name: String, _ detail: String = "") {
        guard !finished else { return }
        stages.append((name, clock.now - begin, detail))
        Self.signposter.emitEvent(
            "Stage", id: signpost,
            "\(name, privacy: .public) \(detail, privacy: .public)")
    }

    /// Ends the interval and writes the summary, e.g. `playing`, `ready`, `failed: …`.
    func finish(_ outcome: String) {
        guard !finished else { return }
        finished = true
        let total = clock.now - begin
        Self.signposter.endInterval("Startup", interval, "\(outcome, privacy: .public)")
        let steps = stages.map { stage in
            "\(stage.name)=\(Self.seconds(stage.at))"
                + (stage.detail.isEmpty ? "" : "(\(stage.detail))")
        }
        .joined(separator: " ")
        Self.logger.notice(
            "startup \(self.videoID, privacy: .public) \(outcome, privacy: .public) total=\(Self.seconds(total), privacy: .public) autoplay=\(self.autoplay) \(steps, privacy: .public)"
        )
    }

    private static func seconds(_ duration: Duration) -> String {
        let value =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", value)
    }
}
