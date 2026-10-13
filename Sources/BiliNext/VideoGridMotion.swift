import Foundation

/// A refresh can reveal the same videos again; scrolling within that revision cannot.
struct VideoGridRevealState {
    private var revision: Int?
    private(set) var revealed: Set<String> = []

    mutating func begin(revision: Int) -> Bool {
        guard self.revision != revision else { return false }
        self.revision = revision
        revealed.removeAll(keepingCapacity: true)
        return true
    }

    mutating func claim(_ visibleIDs: [String]) -> [String] {
        visibleIDs.filter { revealed.insert($0).inserted }
    }

    static func delay(at visibleIndex: Int, count: Int) -> TimeInterval {
        let step = min(0.035, 0.28 / Double(max(1, count - 1)))
        return min(0.28, Double(max(0, visibleIndex)) * step)
    }
}

/// Only an intentional trackpad gesture begun at the top can arm a refresh.
struct VideoGridPullRefreshState {
    static let threshold: CGFloat = 56
    private(set) var tracking = false
    private(set) var distance: CGFloat = 0
    var armed: Bool { tracking && distance >= Self.threshold }

    mutating func begin(atTop: Bool, available: Bool) {
        tracking = atTop && available
        distance = 0
    }

    mutating func update(distance: CGFloat, available: Bool) {
        guard tracking, available else {
            cancel()
            return
        }
        self.distance = max(0, distance)
    }

    mutating func end(available: Bool) -> Bool {
        let refresh = armed && available
        cancel()
        return refresh
    }

    mutating func drag(by delta: CGFloat, atTop: Bool, available: Bool) {
        guard atTop else {
            cancel()
            return
        }
        update(distance: distance + delta, available: available)
    }

    mutating func cancel() {
        tracking = false
        distance = 0
    }
}
