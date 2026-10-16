import BiliNextCore
import Foundation
import Observation

/// Owned by the 简介 view; its structured task supplies cancellation on hide or tab changes.
@MainActor @Observable
final class OnlineViewerPoller {
    struct Target: Hashable, Sendable {
        let bvid: String
        let cid: Int64

        init?(video: Video?, cid: Int64?, isActive: Bool = true) {
            guard isActive, let video, video.episodeID == nil,
                Video.extractBVID(video.bvid) == video.bvid,
                let cid, cid > 0
            else { return nil }
            self.bvid = video.bvid
            self.cid = cid
        }
    }

    private(set) var target: Target?
    private(set) var count: OnlineViewerCount?
    @ObservationIgnored private var generation = UUID()

    func value(for target: Target?) -> OnlineViewerCount? {
        guard let target, target == self.target else { return nil }
        return count
    }

    func stop() {
        generation = UUID()
        target = nil
        count = nil
    }

    func poll(
        _ target: Target,
        load: @MainActor (Target) async throws -> OnlineViewerCount?,
        wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }
    ) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        self.target = target
        count = nil
        defer { if generation == request { stop() } }
        while !Task.isCancelled, generation == request {
            do {
                let result = try await load(target)
                guard !Task.isCancelled, generation == request else { return }
                count = result
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                // Auxiliary metadata failures never become playback errors or a made-up zero;
                // the last good count stays so the intro does not reflow on a blip.
            }
            do { try await wait() } catch { return }
        }
    }
}
