import Foundation

/// Incremental live display scheduling. Call reset when viewport or rendering settings change.
public struct LiveDanmakuTimeline: Sendable {
    private var active: [DanmakuPlacement] = []
    private var scrolling: [Int: DanmakuPlacement] = [:]
    private var top: [Int: Double] = [:]
    private var bottom: [Int: Double] = [:]
    private var seen = Set<String>()
    private var recentIDs: [String] = []
    private var lastClock = -Double.infinity
    private static let maximumActive = 200
    private static let maximumRecent = 4096

    public init() {}

    public mutating func reset() {
        active.removeAll(keepingCapacity: true)
        scrolling.removeAll(keepingCapacity: true)
        top.removeAll(keepingCapacity: true)
        bottom.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        recentIDs.removeAll(keepingCapacity: true)
        lastClock = -.infinity
    }

    /// Returns the complete active set; existing placements retain their lane, start and duration.
    public mutating func append(
        _ comments: [Danmaku], at time: Double, viewport: Double, lanes: Int, duration: Double,
        width: (Danmaku) -> Double
    ) -> [DanmakuPlacement] {
        guard time.isFinite, viewport.isFinite, viewport > 0, lanes > 0,
            duration.isFinite, duration > 0
        else { return [] }
        guard time >= lastClock else { return active }
        let previousClock = lastClock
        lastClock = time
        active.removeAll { !$0.visible(at: time) }
        scrolling = scrolling.filter { $0.value.comment.time + $0.value.duration > time }
        top = top.filter { $0.value > time }
        bottom = bottom.filter { $0.value > time }
        let activeIDs = Set(active.map(\.id))
        let laneCount = min(lanes, Self.maximumActive)
        // Recent IDs are bounded. The monotonic watermark also rejects older batch replay.
        for comment in comments.prefix(Self.maximumRecent).sorted(by: {
            $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
        }) {
            guard comment.time.isFinite, comment.time <= time, comment.time >= previousClock,
                !comment.id.isEmpty, !comment.text.isEmpty, [1, 2, 3, 4, 5].contains(comment.mode),
                !seen.contains(comment.id), !activeIDs.contains(comment.id)
            else { continue }
            seen.insert(comment.id)
            recentIDs.append(comment.id)
            guard active.count < Self.maximumActive else { continue }
            let measured = width(comment)
            guard measured.isFinite else { continue }
            let textWidth = max(1, measured)
            if comment.mode == 4 || comment.mode == 5 {
                guard comment.time + 4 > time else { continue }
                let occupied = comment.mode == 4 ? bottom : top
                guard
                    let lane = (0..<min(2, laneCount)).first(where: {
                        occupied[$0, default: -.infinity] <= comment.time
                    })
                else { continue }
                if comment.mode == 4 {
                    bottom[lane] = comment.time + 4
                } else {
                    top[lane] = comment.time + 4
                }
                active.append(
                    DanmakuPlacement(comment: comment, lane: lane, width: textWidth, duration: 4))
            } else {
                guard comment.time + duration > time else { continue }
                let speed = (viewport + textWidth) / duration
                guard
                    let lane = (0..<laneCount).first(where: { lane in
                        guard let previous = scrolling[lane] else { return true }
                        let oldSpeed = (viewport + previous.width) / previous.duration
                        let clearedRight = previous.comment.time + (previous.width + 16) / oldSpeed
                        let noCatchUp =
                            previous.comment.time + previous.duration - (viewport - 16) / speed
                        return comment.time >= max(clearedRight, noCatchUp)
                    })
                else { continue }
                let placement = DanmakuPlacement(
                    comment: comment, lane: lane, width: textWidth, duration: duration)
                scrolling[lane] = placement
                active.append(placement)
            }
        }
        if recentIDs.count > Self.maximumRecent {
            let removed = recentIDs.count - Self.maximumRecent
            for id in recentIDs.prefix(removed) { seen.remove(id) }
            recentIDs.removeFirst(removed)
        }
        return active
    }
}
