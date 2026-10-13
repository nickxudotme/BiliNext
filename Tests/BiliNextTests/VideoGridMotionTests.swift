import AppKit
import QuartzCore
import Testing

@testable import BiliNext

@Test func cardRevealOnlyClaimsNewlyVisibleIDsUntilARefresh() {
    var state = VideoGridRevealState()
    let firstRevision = state.begin(revision: 1)
    let initial = state.claim(["a", "b", "a"])
    let unchangedRevision = state.begin(revision: 1)
    let nextVisible = state.claim(["b", "c"])
    let revisited = state.claim(["a", "b", "c"])
    #expect(firstRevision)
    #expect(initial == ["a", "b"])
    #expect(!unchangedRevision)
    #expect(nextVisible == ["c"])
    #expect(revisited.isEmpty)
    // Identical refreshed results replay, while old scrolling batches do not.
    let refreshedRevision = state.begin(revision: 2)
    let refreshed = state.claim(["a", "b", "c"])
    #expect(refreshedRevision)
    #expect(refreshed == ["a", "b", "c"])
}

@Test func cardStaggerHasABoundedDelayForLargeVisibleBatches() {
    #expect(VideoGridRevealState.delay(at: 0, count: 1) == 0)
    for count in [2, 6, 20, 500] {
        let delays = (0..<count).map { VideoGridRevealState.delay(at: $0, count: count) }
        #expect(delays.last! <= 0.28)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Test @MainActor func cardRevealAnimatesPresentationAndReuseRestoresFinalState() {
    _ = NSApplication.shared
    let item = VideoGridItem()
    item.view.frame = NSRect(x: 0, y: 0, width: 260, height: 250)
    let frame = item.view.frame
    #expect(type(of: item.view) == NSView.self)
    #expect(item.view.subviews.first?.frame == item.view.bounds)
    item.reveal(at: CACurrentMediaTime(), delay: 0.075, reduceMotion: false)
    let group =
        item.view.layer?.animation(forKey: VideoGridItem.revealAnimationKey) as? CAAnimationGroup
    #expect(group?.duration == 0.28)
    #expect(group?.fillMode == .backwards)
    #expect(group?.animations?.count == 2)
    #expect(item.view.layer?.opacity == 1)
    #expect(item.view.layer.map { CATransform3DIsIdentity($0.transform) } == true)
    #expect(item.view.frame == frame)
    item.prepareForReuse()
    #expect(item.view.layer?.animation(forKey: VideoGridItem.revealAnimationKey) == nil)
    #expect(item.view.layer?.opacity == 1)
    #expect(item.view.layer.map { CATransform3DIsIdentity($0.transform) } == true)
}

@Test @MainActor func cancellingARevealAndReduceMotionNeverLeaveAnInvisibleCard() {
    _ = NSApplication.shared
    let item = VideoGridItem()
    item.reveal(at: CACurrentMediaTime(), delay: 0.12, reduceMotion: false)
    item.cancelReveal()
    #expect(item.view.layer?.animation(forKey: VideoGridItem.revealAnimationKey) == nil)
    #expect(item.view.layer?.opacity == 1)
    item.reveal(at: CACurrentMediaTime(), delay: 0.12, reduceMotion: true)
    #expect(item.view.layer?.animation(forKey: VideoGridItem.revealAnimationKey) == nil)
    #expect(item.view.layer?.opacity == 1)
    #expect(item.view.layer.map { CATransform3DIsIdentity($0.transform) } == true)
}

@Test func pullRefreshRequiresTopThresholdAndOneRelease() {
    var state = VideoGridPullRefreshState()
    state.begin(atTop: false, available: true)
    state.update(distance: 100, available: true)
    let belowTop = state.end(available: true)
    #expect(!belowTop)
    state.begin(atTop: true, available: true)
    state.update(distance: 55, available: true)
    let belowThreshold = state.end(available: true)
    #expect(!belowThreshold)
    state.begin(atTop: true, available: true)
    state.update(distance: 60, available: true)
    #expect(state.armed)
    let released = state.end(available: true)
    let repeatedRelease = state.end(available: true)
    #expect(released)
    #expect(!repeatedRelease)
}

@Test func pullRefreshDoesNotQueueBehindLoadingOrAnAbandonedGesture() {
    var state = VideoGridPullRefreshState()
    state.begin(atTop: true, available: false)
    state.update(distance: 80, available: true)
    let initiallyBusy = state.end(available: true)
    #expect(!initiallyBusy)
    state.begin(atTop: true, available: true)
    state.update(distance: 80, available: true)
    state.update(distance: 80, available: false)
    let becameBusy = state.end(available: true)
    #expect(!becameBusy)
    state.begin(atTop: true, available: true)
    state.update(distance: 80, available: true)
    state.update(distance: 20, available: true)
    let retracted = state.end(available: true)
    #expect(!retracted)
    state.begin(atTop: true, available: true)
    state.update(distance: 80, available: true)
    state.cancel()
    let cancelled = state.end(available: true)
    #expect(!cancelled)
}

@Test func pullRefreshTracksDirectDeltasAndCancelsWhenScrollingIntoTheList() {
    var state = VideoGridPullRefreshState()
    state.begin(atTop: true, available: true)
    state.drag(by: 0, atTop: true, available: true)
    state.drag(by: 30, atTop: true, available: true)
    state.drag(by: 30, atTop: true, available: true)
    #expect(state.armed)
    state.drag(by: -20, atTop: true, available: true)
    #expect(!state.armed)
    state.drag(by: 20, atTop: true, available: true)
    let released = state.end(available: true)
    #expect(released)
    state.begin(atTop: true, available: true)
    state.drag(by: -20, atTop: false, available: true)
    state.drag(by: 100, atTop: true, available: true)
    let returnedToTop = state.end(available: true)
    #expect(!returnedToTop)
}

@Test @MainActor func nativePullRefreshKeepsDirectDistanceAcrossBoundsNotifications() throws {
    _ = NSApplication.shared
    let scroll = VideoGridScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
    var refreshes = 0
    scroll.canRefresh = { true }
    scroll.refreshRequested = { refreshes += 1 }
    func send(delta: Int32, phase: Int64) throws {
        let cg = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: delta, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.hasPreciseScrollingDeltas)
        scroll.scrollWheel(with: event)
    }
    try send(delta: 30, phase: 1)
    scroll.validatePullPosition()
    try send(delta: 30, phase: 2)
    scroll.validatePullPosition()
    try send(delta: 0, phase: 4)
    #expect(refreshes == 1)
    try send(delta: 0, phase: 4)
    #expect(refreshes == 1)
    scroll.updateRefreshState(loading: false)
    try send(delta: 30, phase: 1)
    scroll.contentView.bounds.origin.y = 10
    scroll.validatePullPosition()
    scroll.contentView.bounds.origin.y = 0
    try send(delta: 100, phase: 2)
    try send(delta: 0, phase: 4)
    #expect(refreshes == 1)
}
