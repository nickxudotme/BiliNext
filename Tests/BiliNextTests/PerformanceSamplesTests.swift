import Foundation
import Testing

@testable import BiliNext

@Test func performanceSamplesMeasureDeliveredCallbacksAt120Hz() {
    var samples = PerformanceSamples()
    for index in 0...240 {
        let time = Double(index) / 120
        samples.record(time: time, budget: 1.0 / 120, target: time + 1.0 / 120)
    }
    let value = samples.snapshot(screenMaximum: 120)
    #expect(abs(value.callbacksPerSecond - 120) < 0.01)
    #expect(abs(value.p95Milliseconds - 1000.0 / 120) < 0.01)
    #expect(value.overBudget == 0 && value.lateMilliseconds == 0)
    #expect(value.screenMaximum == 120)
}

@Test func performanceSamplesExposeHitchesAndExpireTheirHistory() {
    var samples = PerformanceSamples()
    let budget = 1.0 / 120
    samples.record(time: 0, budget: budget, target: budget)
    samples.record(time: budget, budget: budget, target: budget * 2)
    samples.record(time: budget * 5, budget: budget, target: budget * 4)
    let hitch = samples.snapshot(screenMaximum: 120)
    #expect(hitch.overBudget == 1)
    #expect(abs(hitch.worstMilliseconds - budget * 4 * 1000) < 0.01)
    #expect(abs(hitch.lateMilliseconds - budget * 1000) < 0.01)
    // After two more seconds of smooth delivery, the old hitch is no longer displayed.
    for index in 6...260 {
        let time = Double(index) * budget
        samples.record(time: time, budget: budget, target: time + budget)
    }
    #expect(samples.snapshot(screenMaximum: 120).overBudget == 0)
    samples.reset()
    #expect(samples.snapshot(screenMaximum: 120).callbacksPerSecond == 0)
    samples.record(time: 99, budget: budget, target: 99 + budget)
    #expect(samples.snapshot(screenMaximum: 120).worstMilliseconds == 0)
}

@Test func performanceSamplesDoNotTreatAdaptiveRefreshChangesAsDroppedFrames() {
    var samples = PerformanceSamples()
    samples.record(time: 0, budget: 1.0 / 120, target: 1.0 / 120)
    samples.record(time: 1.0 / 60, budget: 1.0 / 60, target: 2.0 / 60)
    samples.record(time: 2.0 / 60, budget: 1.0 / 60, target: 3.0 / 60)
    samples.record(time: .nan, budget: 0, target: .infinity)
    let value = samples.snapshot(screenMaximum: 120)
    #expect(value.overBudget == 0)
    #expect(abs(value.callbacksPerSecond - 60) < 0.01)
}
