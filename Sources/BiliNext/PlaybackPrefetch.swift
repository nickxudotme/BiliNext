import BiliNextCore
import Foundation

/// Fetched and in-flight playurl responses shared by every tab, so opening a video can reuse
/// a request started earlier: while its detail loads, or when its card was hovered.
@MainActor
final class PlaybackPrefetch {
    struct Key: Hashable {
        let bvid: String
        let cid: Int64
        let quality: Int
    }

    private struct Entry {
        let task: Task<Playback, Error>
        let started: Date
    }

    /// Entries expire well before Bilibili's signed media URLs do.
    static let lifetime: TimeInterval = 10 * 60
    static let capacity = 32
    /// Hover prefetches yield to everything else beyond this many at once.
    static let speculativeLimit = 3

    private let fetch: (Key) async throws -> Playback
    private var entries: [Key: Entry] = [:]
    private var speculative = 0

    init(api: BilibiliAPI) {
        fetch = { key in try await api.playback(bvid: key.bvid, cid: key.cid, quality: key.quality)
        }
    }

    init(fetch: @escaping (Key) async throws -> Playback) {
        self.fetch = fetch
    }

    /// The response for `key`, joining a request already under way or starting one. The
    /// entry is consumed, so a later open of the same video gets fresh URLs.
    func playback(for key: Key) async throws -> Playback {
        let task = entry(for: key).task
        entries[key] = nil
        return try await task.value
    }

    /// Starts the request for an open that will need it shortly.
    func warm(_ key: Key) {
        _ = entry(for: key)
    }

    /// Starts a request the user may never use, as when hovering a card.
    func speculate(_ key: Key) {
        guard entries[key] == nil, speculative < Self.speculativeLimit else { return }
        speculative += 1
        let task = entry(for: key).task
        Task { [weak self] in
            _ = try? await task.value
            self?.speculative -= 1
        }
    }

    /// How long ago a reusable request for `key` started, for startup diagnostics.
    func age(of key: Key) -> TimeInterval? {
        entries[key].map { Date().timeIntervalSince($0.started) }.flatMap {
            $0 < Self.lifetime ? $0 : nil
        }
    }

    func removeAll() {
        entries.removeAll()
    }

    private func entry(for key: Key) -> Entry {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.started) < Self.lifetime }
        if let entry = entries[key] { return entry }
        if entries.count >= Self.capacity,
            let oldest = entries.min(by: { $0.value.started < $1.value.started })?.key
        {
            entries[oldest] = nil
        }
        let fetch = fetch
        let task = Task { () throws -> Playback in
            let playback = try await fetch(key)
            DNSWarmup.resolve(playback)
            return playback
        }
        let entry = Entry(task: task, started: now)
        entries[key] = entry
        // A failed request is not worth keeping; the open retries it directly.
        Task { [weak self] in
            if (try? await task.value) == nil, self?.entries[key]?.started == now {
                self?.entries[key] = nil
            }
        }
        return entry
    }
}

/// Resolves media hosts ahead of mpv, whose own lookup blocks the start of playback. Only the
/// system's DNS cache is warmed; mpv still opens its own connections.
enum DNSWarmup {
    private static let queue = DispatchQueue(
        label: "dev.bilinext.dns-warmup", qos: .userInitiated, attributes: .concurrent)

    static func resolve(_ playback: Playback) {
        let urls =
            [playback.videoStream?.urls.prefix(2), playback.audioStream?.urls.prefix(2)]
            .compactMap { $0 }.flatMap { $0 } + [playback.url]
        for host in Set(urls.compactMap(\.host)) {
            queue.async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                if getaddrinfo(host, "443", &hints, &result) == 0 { freeaddrinfo(result) }
            }
        }
    }
}
