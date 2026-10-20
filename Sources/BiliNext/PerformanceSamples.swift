import Foundation

/// Display-link delivery timing diagnoses main-run-loop pacing, not GPU-presented frames.
struct PerformanceSamples {
    struct Snapshot {
        var callbacksPerSecond = 0.0
        var p95Milliseconds = 0.0
        var worstMilliseconds = 0.0
        var lateMilliseconds = 0.0
        var overBudget = 0
        var screenMaximum = 0
    }
    private struct Sample {
        let time: Double
        let interval: Double
        let lateness: Double
        let overBudget: Bool
    }
    private var previous: Double?
    private var previousBudget: Double?
    private var samples: [Sample] = []

    mutating func reset() {
        previous = nil
        previousBudget = nil
        samples.removeAll(keepingCapacity: true)
    }

    mutating func record(time: Double, budget: Double, target: Double) {
        guard time.isFinite, budget.isFinite, budget > 0, target.isFinite else { return }
        defer {
            previous = time
            previousBudget = budget
        }
        guard let previous, time > previous else { return }
        let interval = time - previous
        let stableBudget = previousBudget.map { abs($0 - budget) < budget * 0.1 } ?? false
        samples.append(
            Sample(
                time: time, interval: interval, lateness: max(0, time - target),
                overBudget: stableBudget && interval > budget * 1.5))
        samples.removeAll { $0.time < time - 2 }
    }

    func snapshot(screenMaximum: Int) -> Snapshot {
        let sorted = samples.map(\.interval).sorted()
        guard !sorted.isEmpty else { return Snapshot(screenMaximum: screenMaximum) }
        let total = sorted.reduce(0, +)
        return Snapshot(
            callbacksPerSecond: Double(sorted.count) / total,
            p95Milliseconds: sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)] * 1000,
            worstMilliseconds: (sorted.last ?? 0) * 1000,
            lateMilliseconds: (samples.map(\.lateness).max() ?? 0) * 1000,
            overBudget: samples.filter(\.overBudget).count, screenMaximum: screenMaximum)
    }
}
