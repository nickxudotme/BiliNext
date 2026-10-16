import Foundation
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

@Test func hiddenDrawerAlsoRevealsFromTheWindowButtonCorner() {
    let corner = DrawerActivation.cornerSize
    #expect(DrawerActivation.zone(x: 40, top: 24, width: 220, pinned: false) == 1)
    #expect(
        DrawerActivation.zone(x: corner.width, top: corner.height, width: 220, pinned: false) == 1)
    #expect(DrawerActivation.zone(x: corner.width + 1, top: 24, width: 220, pinned: false) == 2)
    #expect(DrawerActivation.zone(x: 40, top: corner.height + 1, width: 220, pinned: false) == 2)
    #expect(DrawerActivation.zone(x: 40, top: 24, width: 220, pinned: true) == 2)
}

@Test func fullscreenToolbarDoesNotRevealHiddenSidebar() {
    for x in [CGFloat(4), 40, 100, 160, 224] {
        #expect(
            DrawerActivation.zone(x: x, top: 24, width: 220, pinned: false, fullScreen: true) == 2)
    }
    for top in [CGFloat(0), 24, 300] {
        #expect(
            DrawerActivation.zone(x: 3, top: top, width: 220, pinned: false, fullScreen: true) == 1)
    }
}
