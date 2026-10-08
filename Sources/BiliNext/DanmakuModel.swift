import BiliNextCore
import SwiftUI

@MainActor
final class DanmakuModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published var comments: [Danmaku] = []
    @Published var error: String?
    @Published var loading = false
    @Published var enabled =
        UserDefaults.standard.object(forKey: "danmaku.enabled") as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "danmaku.enabled")
            currentSegment = nil
            if !enabled {
                task?.cancel()
                loading = false
            }
        }
    }
    private var cid: Int64?
    private var currentSegment: String?
    private var cache: [Int: [Danmaku]] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func configure(cid: Int64?) {
        task?.cancel()
        generation = UUID()
        self.cid = cid
        currentSegment = nil
        cache = [:]
        comments = []
        revision += 1
        error = nil
        loading = false
    }
    func retry() { currentSegment = nil }
    func update(time: Double, duration: Double, api: BilibiliAPI) {
        guard enabled, let cid else { return }
        let segment = Int(max(0, time) / 360) + 1
        let lastSegment = max(segment, duration > 0 ? Int(duration / 360) + 1 : segment)
        let wanted = Array(max(1, segment - 1)...min(lastSegment, segment + 1))
        let window = wanted.map(String.init).joined(separator: ",")
        guard window != currentSegment else { return }
        currentSegment = window
        task?.cancel()
        generation = UUID()
        let token = generation
        cache = cache.filter { wanted.contains($0.key) }
        publish()
        loading = true
        error = nil
        task = Task {
            // Load the active segment before its neighbors.
            for number in [segment] + wanted.filter({ $0 != segment }) where cache[number] == nil {
                do {
                    let items = try await api.danmaku(cid: cid, segment: number)
                    guard !Task.isCancelled, token == generation else { return }
                    cache[number] = items
                    publish()
                } catch {
                    guard !Task.isCancelled, token == generation else { return }
                    if number == segment { self.error = "当前时段弹幕加载失败，可在设置中重试。" }
                }
            }
            if token == generation { loading = false }
        }
    }
    private func publish() {
        revision += 1
        var seen = Set<String>()
        comments = cache.values.flatMap { $0 }.filter { seen.insert($0.id).inserted }.sorted {
            $0.time < $1.time
        }
    }
}
