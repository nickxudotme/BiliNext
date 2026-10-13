import Foundation

/// A shared serial outbox stores progress only; authentication remains in the API's cookie jar.
@MainActor
final class WatchHistoryOutbox {
    struct Entry: Codable, Equatable {
        let id: UUID
        let accountID: Int64
        let progress: WatchHistoryReporter.Progress
        let updatedAt: Date
        var failures: Int
        var retryAt: Date
    }
    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliNext/WatchHistory/pending.json")
    }
    private(set) var entries: [Entry] = []
    private let store: URL?
    private let capacity: Int
    private let lifetime: TimeInterval
    private let activeAccount: () -> Int64?
    private let send: (Entry) async throws -> Void
    private let onSuccess: () -> Void
    private let onError: (Error) -> Void
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var sending = false
    private let automatic: Bool

    init(
        store: URL?, capacity: Int = 100, lifetime: TimeInterval = 86400,
        automatic: Bool = true, activeAccount: @escaping () -> Int64?,
        send: @escaping (Entry) async throws -> Void,
        onSuccess: @escaping () -> Void = {}, onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.store = store
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
        self.automatic = automatic
        self.activeAccount = activeAccount
        self.send = send
        self.onSuccess = onSuccess
        self.onError = onError
        if let store, let data = try? Data(contentsOf: store),
            let saved = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = saved.filter { $0.accountID > 0 && Self.valid($0.progress) }.map { entry in
                var entry = entry
                entry.failures = max(0, min(entry.failures, 100))
                return entry
            }
        }
        prune()
    }

    func enqueue(_ progress: WatchHistoryReporter.Progress, accountID: Int64, now: Date = Date()) {
        guard accountID > 0, Self.valid(progress) else { return }
        // Keep the newest unsent snapshot, including a legitimate backwards seek.
        entries.removeAll {
            $0.accountID == accountID && $0.progress.bvid == progress.bvid
                && $0.progress.cid == progress.cid
        }
        entries.append(
            Entry(
                id: UUID(), accountID: accountID, progress: progress,
                updatedAt: now, failures: 0, retryAt: now))
        prune(now: now)
        persist()
        if !sending, worker != nil {
            worker?.cancel()
            worker = nil
            generation = UUID()
        }
        resume()
    }

    func accountChanged() {
        worker?.cancel()
        worker = nil
        generation = UUID()
        prune()
        persist()
        resume()
    }

    /// At most one pass of ready snapshots; retries are delayed rather than recursive.
    func sendReady(now: Date = Date()) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        let scope = generation
        guard let account = activeAccount() else { return }
        let ready = entries.filter { $0.accountID == account && $0.retryAt <= now }
        for entry in ready {
            guard !Task.isCancelled, scope == generation, activeAccount() == account else { return }
            guard entries.contains(where: { $0.id == entry.id }) else { continue }
            do {
                try await send(entry)
                guard scope == generation, activeAccount() == account else { return }
                entries.removeAll { $0.id == entry.id }
                onSuccess()
            } catch is CancellationError { return } catch {
                guard scope == generation else { return }
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index].failures += 1
                    let pauses: [TimeInterval] = [1, 5, 30, 60]
                    entries[index].retryAt = Date().addingTimeInterval(
                        pauses[min(entries[index].failures - 1, pauses.count - 1)])
                }
                onError(error)
            }
            persist()
        }
    }

    func resume() {
        guard automatic, worker == nil, let account = activeAccount(),
            entries.contains(where: { $0.accountID == account })
        else { return }
        let scope = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == scope { self.worker = nil } }
            while !Task.isCancelled, scope == self.generation, self.activeAccount() == account {
                self.prune()
                self.persist()
                guard
                    let next = self.entries.filter({ $0.accountID == account }).map(\.retryAt).min()
                else { break }
                let wait = max(0, min(60, next.timeIntervalSinceNow))
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { break }
                }
                await self.sendReady()
                if self.sending {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
                }
            }
        }
    }

    func drain(timeout: TimeInterval = 2) async {
        // Final progress may replace an entry sleeping in backoff. Make it ready now.
        let account = activeAccount()
        for index in entries.indices where entries[index].accountID == account {
            entries[index].retryAt = Date()
        }
        if !sending {
            worker?.cancel()
            worker = nil
            generation = UUID()
        }
        persist()
        resume()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, entries.contains(where: { $0.accountID == account }) {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
        }
        worker?.cancel()
        worker = nil
        generation = UUID()
        persist()
    }

    private static func valid(_ progress: WatchHistoryReporter.Progress) -> Bool {
        !progress.bvid.isEmpty && progress.cid > 0 && progress.position.isFinite
            && progress.position >= 0
    }

    private func prune(now: Date = Date()) {
        entries.removeAll {
            now.timeIntervalSince($0.updatedAt) > lifetime
                || $0.updatedAt > now.addingTimeInterval(60)
        }
        entries = Array(entries.suffix(capacity))
    }

    private func persist() {
        guard let store else { return }
        do {
            let parent = store.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: store, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.path)
        } catch { onError(error) }
    }
}
