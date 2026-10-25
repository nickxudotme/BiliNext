import BiliNextCore
import Foundation
import os

/// One bounded recovery budget per media/quality request. The owner cancels it on replacement.
@MainActor
final class PlaybackRecovery {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.nickxu.BiliNext",
        category: "PlaybackRecovery")
    struct Options: Equatable {
        var allowAV1 = true
        var allowHEVC = true
        var preferDASH = true
    }
    struct Source {
        let playback: Playback
        let video: URL
        let audio: URL?
        var identity: String { video.absoluteString + "\n" + (audio?.absoluteString ?? "") }
    }
    private(set) var attempts = 0
    private(set) var recovering = false
    private(set) var cancelled = false
    private var playback: Playback
    private var options = Options()
    private var refreshed = false
    private var tried = Set<String>()
    private var task: Task<Void, Never>?
    private let limit: Int
    private let fetch: (Options) async throws -> Playback
    private let load: (Source, Int, String) throws -> Void
    private let onState: (Bool, String?) -> Void
    private let delay: (Int) async throws -> Void

    init(
        playback: Playback, limit: Int = 8,
        fetch: @escaping (Options) async throws -> Playback,
        load: @escaping (Source, Int, String) throws -> Void,
        onState: @escaping (Bool, String?) -> Void,
        delay: @escaping (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .milliseconds(min(2000, 250 * attempt)))
        }
    ) {
        self.playback = playback
        self.limit = max(1, limit)
        self.fetch = fetch
        self.load = load
        self.onState = onState
        self.delay = delay
    }

    func start() throws {
        guard let source = nextSource() else { throw MPVError(message: "视频没有可用播放地址") }
        try attempt(source, reason: "initial")
    }

    func failed(code: Int32?, message: String, refreshFirst: Bool = false) {
        guard !cancelled, task == nil else { return }
        // Only media loading/format errors can be repaired by changing sources.
        guard code.map({ [-13, -16, -17, -18, -20].contains($0) }) ?? true else {
            onState(false, message)
            cancel()
            return
        }
        recovering = true
        onState(true, nil)
        let formatFailure = [-17, -18].contains(code ?? 0)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var requiresRefresh = refreshFirst
            do {
                while self.attempts < self.limit {
                    try await self.delay(self.attempts)
                    try Task.checkCancellation()
                    guard !self.cancelled else { return }
                    if !formatFailure, !requiresRefresh, let source = self.nextSource() {
                        do {
                            try self.attempt(source, reason: "alternate-source")
                            return
                        } catch { continue }
                    }
                    let reason: String
                    if requiresRefresh || (!formatFailure && !self.refreshed) {
                        self.refreshed = true
                        reason = requiresRefresh ? "refresh-after-eof" : "refresh-playurl"
                        if requiresRefresh {
                            // A paused connection can close without invalidating its URL.
                            // Reopening the refreshed URL is valid even if it is unchanged.
                            self.tried.removeAll()
                            requiresRefresh = false
                        }
                    } else if self.options.allowAV1
                        && self.playback.videoStream?.codec.hasPrefix("av01.") == true
                    {
                        self.options.allowAV1 = false
                        reason = "disable-av1"
                    } else if self.options.allowHEVC && self.playback.videoStream != nil {
                        self.options.allowAV1 = false
                        self.options.allowHEVC = false
                        reason = "use-avc"
                    } else if self.options.preferDASH && self.playback.videoStream != nil {
                        self.options.preferDASH = false
                        reason = "use-mp4"
                    } else {
                        break
                    }
                    // API permission/auth failures propagate immediately; they aren't CDN errors.
                    let refreshed = try await self.fetch(self.options)
                    try Task.checkCancellation()
                    guard !self.cancelled else { return }
                    self.playback = refreshed
                    if let source = self.nextSource() {
                        do {
                            try self.attempt(source, reason: reason)
                            return
                        } catch { continue }
                    }
                }
                self.recovering = false
                self.onState(false, "播放恢复未成功：\(message)。可以重新加载。")
                self.cancelled = true
            } catch is CancellationError {
                // Replacement/stop owns the new UI state.
            } catch {
                guard !self.cancelled else { return }
                self.recovering = false
                self.onState(false, error.localizedDescription)
                self.cancelled = true
            }
        }
    }

    func loaded() {
        guard !cancelled else { return }
        recovering = false
        onState(false, nil)
    }

    func cancel() {
        cancelled = true
        recovering = false
        task?.cancel()
        task = nil
    }

    func waitForRecovery() async { await task?.value }

    private func attempt(_ source: Source, reason: String) throws {
        attempts += 1
        tried.insert(source.identity)
        Self.logger.notice(
            "Media attempt: phase=\(reason, privacy: .public) attempt=\(self.attempts, privacy: .public) video-host=\(source.video.host ?? "local", privacy: .public)"
        )
        try load(source, attempts, reason)
    }

    private func nextSource() -> Source? {
        let videos = playback.videoStream?.urls ?? [playback.url]
        let audios: [URL?] = playback.audioStream?.urls.map { Optional($0) } ?? [nil]
        // Rotate both tracks first, then alternate each track; never expand an unbounded product.
        var candidates: [Source] = []
        for index in 0..<min(limit, max(videos.count, audios.count)) {
            guard !videos.isEmpty, !audios.isEmpty else { break }
            candidates.append(
                Source(
                    playback: playback, video: videos[index % videos.count],
                    audio: audios[index % audios.count]))
        }
        for video in videos.prefix(limit) {
            candidates.append(Source(playback: playback, video: video, audio: audios.first ?? nil))
        }
        for audio in audios.prefix(limit) {
            if let video = videos.first {
                candidates.append(Source(playback: playback, video: video, audio: audio))
            }
        }
        return candidates.first { !tried.contains($0.identity) }
    }
}
