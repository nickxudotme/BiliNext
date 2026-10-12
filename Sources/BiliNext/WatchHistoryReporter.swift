import Foundation

/// Wall-clock throttling and an ordered queue prevent older progress overwriting a final pause.
@MainActor
final class WatchHistoryReporter {
    struct Progress: Equatable {
        let bvid: String
        let cid: Int64
        let position: Double
    }
    private let send: (Progress) async throws -> Void
    private let onError: (Error) -> Void
    private var current: Progress?
    private var lastReport = Date.distantPast
    private var lastQueued: Progress?
    private var wasPlaying = false
    private var pending: Task<Void, Never>?

    init(send: @escaping (Progress) async throws -> Void, onError: @escaping (Error) -> Void) {
        self.send = send
        self.onError = onError
    }

    func update(
        bvid: String, cid: Int64, position: Double, playing: Bool, buffering: Bool,
        now: Date = Date()
    ) {
        guard position.isFinite, position >= 0 else { return }
        if current?.bvid != bvid || current?.cid != cid {
            flush()
            current = nil
            lastQueued = nil
            lastReport = .distantPast
            wasPlaying = false
        }
        // Loading a paused tab is not a viewing event. Buffer stalls preserve playback intent.
        if playing && !buffering && position > 0 {
            current = Progress(bvid: bvid, cid: cid, position: position)
            if !wasPlaying || now.timeIntervalSince(lastReport) >= 15 {
                enqueue(now: now)
            }
            wasPlaying = true
        } else if !playing && wasPlaying {
            current = Progress(bvid: bvid, cid: cid, position: position)
            flush(now: now)
        }
    }

    func flush(now: Date = Date()) {
        enqueue(now: now)
        wasPlaying = false
    }

    func waitForPendingReports() async { await pending?.value }

    private func enqueue(now: Date) {
        guard let current, current != lastQueued else { return }
        lastReport = now
        lastQueued = current
        let previous = pending
        let send = send
        let onError = onError
        pending = Task {
            await previous?.value
            do { try await send(current) } catch { onError(error) }
        }
    }
}
