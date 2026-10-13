import Foundation

/// Wall-clock throttling and an ordered queue prevent older progress overwriting a final pause.
@MainActor
final class WatchHistoryReporter {
    struct Progress: Equatable, Codable {
        let bvid: String
        let cid: Int64
        let position: Double
        var accountID: Int64? = nil
    }
    private let send: (Progress) async throws -> Void
    private let onError: (Error) -> Void
    private let account: () -> Int64?
    private var current: Progress?
    private var lastReport = Date.distantPast
    private var lastQueued: Progress?
    private var wasPlaying = false
    private var pending: Task<Void, Never>?

    init(
        send: @escaping (Progress) async throws -> Void, onError: @escaping (Error) -> Void,
        account: @escaping () -> Int64? = { nil }
    ) {
        self.send = send
        self.onError = onError
        self.account = account
    }

    func update(
        bvid: String, cid: Int64, position: Double, playing: Bool, buffering: Bool,
        now: Date = Date()
    ) {
        guard position.isFinite, position >= 0 else { return }
        if current?.bvid != bvid || current?.cid != cid || current?.accountID != account() {
            flush()
            current = nil
            lastQueued = nil
            lastReport = .distantPast
            wasPlaying = false
        }
        // Loading a paused tab is not a viewing event. Buffer stalls preserve playback intent.
        if playing && !buffering && position > 0 {
            current = Progress(bvid: bvid, cid: cid, position: position, accountID: account())
            if !wasPlaying || now.timeIntervalSince(lastReport) >= 15 {
                enqueue(now: now)
            }
            wasPlaying = true
        } else if !playing && wasPlaying {
            current = Progress(bvid: bvid, cid: cid, position: position, accountID: account())
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
