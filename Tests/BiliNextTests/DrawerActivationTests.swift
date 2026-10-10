import Testing

@testable import BiliNext

@Test func fullscreenScreenEdgeAndFloatingDrawerCorridor() {
    // The previous outside-only activation never fired at x == 0 in fullscreen.
    #expect(DrawerActivation.zone(x: 0, width: 220, pinned: false) == 1)
    #expect(DrawerActivation.zone(x: 3, width: 220, pinned: false) == 1)
    #expect(DrawerActivation.zone(x: -220, width: 220, pinned: false) == 1)
    #expect(DrawerActivation.zone(x: -221, width: 220, pinned: false) == 0)
    #expect(DrawerActivation.zone(x: 100, width: 220, pinned: false) == 2)
    #expect(DrawerActivation.zone(x: 224, width: 220, pinned: false) == 2)
    #expect(DrawerActivation.zone(x: 225, width: 220, pinned: false) == 0)
    #expect(DrawerActivation.zone(x: nil, width: 220, pinned: false) == 0)
}
