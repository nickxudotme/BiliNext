import Testing

@testable import BiliNextCore

private func liveComment(_ id: String, time: Double = 0, mode: Int = 1) -> Danmaku {
    Danmaku(id: id, time: time, mode: mode, text: id)
}

@Test func liveTimelineDropsSaturatedBurstsWithoutRelayingExistingPlacements() {
    var timeline = LiveDanmakuTimeline()
    let first = timeline.append(
        (0..<10).map { liveComment("\($0)") }, at: 0, viewport: 1000, lanes: 3, duration: 8
    ) { _ in 100 }
    #expect(first.count == 3 && Set(first.map(\.lane)).count == 3)
    let next = timeline.append(
        [liveComment("new", time: 1)], at: 1, viewport: 1000, lanes: 3, duration: 8
    ) { _ in 100 }
    #expect(next.count == 4)
    for old in first {
        let retained = next.first { $0.id == old.id }
        #expect(
            retained?.lane == old.lane && retained?.width == old.width
                && retained?.duration == old.duration)
        #expect(retained?.comment.time == old.comment.time)
    }
    let added = next.first { $0.id == "new" }
    #expect(added?.lane == 0)
    #expect(first[0].x(at: 1, viewport: 1000) + first[0].width + 16 <= 1000)
}

@Test func liveTimelinePreventsFasterCommentsCatchingEarlierWideText() {
    var timeline = LiveDanmakuTimeline()
    _ = timeline.append([liveComment("small")], at: 0, viewport: 1000, lanes: 1, duration: 8) { _ in
        100
    }
    let refused = timeline.append(
        [liveComment("fast", time: 1)], at: 1, viewport: 1000, lanes: 1, duration: 8
    ) { _ in 500 }
    #expect(refused.map(\.id) == ["small"])
    let accepted = timeline.append(
        [liveComment("later", time: 3)], at: 3, viewport: 1000, lanes: 1, duration: 8
    ) { _ in 500 }
    #expect(accepted.count == 2)
    for time in stride(from: 3.0, through: 7.9, by: 0.1) {
        #expect(
            accepted[0].x(at: time, viewport: 1000) + accepted[0].width + 16 <= accepted[1].x(
                at: time, viewport: 1000) + 0.0001)
    }
}

@Test func liveTimelineExpiresAndDoesNotReplayDuplicateOrDroppedMessages() {
    var timeline = LiveDanmakuTimeline()
    let original = liveComment("a-first")
    _ = timeline.append(
        [original, liveComment("z-dropped")], at: 0, viewport: 1000, lanes: 1, duration: 8
    ) { _ in 100 }
    let duplicate = timeline.append(
        [original, liveComment("a-first", time: 1), liveComment("z-dropped", time: 1)], at: 1,
        viewport: 1000, lanes: 1, duration: 8
    ) { _ in 100 }
    #expect(duplicate.map(\.id) == ["a-first"])
    #expect(duplicate.count == 1)
    #expect(
        timeline.append([original], at: 8, viewport: 1000, lanes: 1, duration: 8) { _ in 100 }
            .isEmpty)
    #expect(
        timeline.append(
            [liveComment("fresh", time: 8)], at: 8, viewport: 1000, lanes: 1, duration: 8
        ) { _ in 100 }.count == 1)
    timeline.reset()
    #expect(
        timeline.append([original], at: 0, viewport: 1000, lanes: 1, duration: 8) { _ in 100 }
            .first?.id == "a-first")
}

@Test func liveTimelineBoundsActiveItemsAndHandlesFixedModeExpiry() {
    var timeline = LiveDanmakuTimeline()
    let active = timeline.append(
        (0..<250).map { liveComment("\($0)") }, at: 0, viewport: 1000, lanes: 10000, duration: 8
    ) { _ in 100 }
    #expect(active.count == 200)
    timeline.reset()
    let fixed = timeline.append(
        [liveComment("top", mode: 5), liveComment("bottom", mode: 4)], at: 0, viewport: 1000,
        lanes: 3, duration: 8
    ) { _ in 100 }
    #expect(fixed.count == 2 && fixed.allSatisfy { $0.duration == 4 })
    #expect(timeline.append([], at: 4, viewport: 1000, lanes: 3, duration: 8) { _ in 100 }.isEmpty)
}
