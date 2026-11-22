import AppKit
import QuartzCore
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Test func sidebarAndContentShareTransitionAndRetainHosts() throws {
    _ = NSApplication.shared
    typealias Shell = SidebarTransitionHost<Color, Color>
    var state = Shell.Configuration(
        pinned: true, revealed: false, edgeInset: 0, sidebarWidth: 220, reduceMotion: false)
    let host = Shell.Host(configuration: state, pages: .black, sidebar: .gray)
    host.frame = NSRect(x: 0, y: 0, width: 1800, height: 1100)
    host.layout()
    let pages = host.pages
    let sidebar = host.sidebar
    #expect(pages.frame == NSRect(x: 220, y: 0, width: 1580, height: 1100))

    state.pinned = false
    host.transition(to: state, animated: true)
    let pageAnimation = try #require(
        pages.layer?.animation(forKey: Shell.Host.animationKey) as? CAAnimationGroup)
    let sidebarAnimation = try #require(
        sidebar.layer?.animation(forKey: Shell.Host.animationKey) as? CAAnimationGroup)
    #expect(pageAnimation.beginTime == sidebarAnimation.beginTime)
    #expect(pageAnimation.duration == sidebarAnimation.duration)
    #expect(pageAnimation.duration == Motion.panelDuration)
    #expect(pages.frame == host.bounds)
    #expect(sidebar.frame.minX == -220)

    // At several intermediate positions, the visible sidebar edge and content
    // edge must stay together. A page that jumped to its destination fails this.
    func value(_ group: CAAnimationGroup, key: String, end: Bool) throws -> NSValue {
        let animation = try #require(
            group.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == key })
        return try #require((end ? animation.toValue : animation.fromValue) as? NSValue)
    }
    let pageStart = try value(pageAnimation, key: "position", end: false).pointValue
    let pageEnd = try value(pageAnimation, key: "position", end: true).pointValue
    let boundsStart = try value(pageAnimation, key: "bounds", end: false).rectValue
    let boundsEnd = try value(pageAnimation, key: "bounds", end: true).rectValue
    let sidebarStart = try value(sidebarAnimation, key: "position", end: false).pointValue
    let sidebarEnd = try value(sidebarAnimation, key: "position", end: true).pointValue
    let pageAnchor = try #require(pages.layer).anchorPoint.x
    let sidebarAnchor = try #require(sidebar.layer).anchorPoint.x
    for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let pageX = pageStart.x + (pageEnd.x - pageStart.x) * progress
        let width = boundsStart.width + (boundsEnd.width - boundsStart.width) * progress
        let sidebarX = sidebarStart.x + (sidebarEnd.x - sidebarStart.x) * progress
        let sidebarEdge = sidebarX - sidebar.frame.width * sidebarAnchor + 220
        #expect(abs(pageX - width * pageAnchor - sidebarEdge) < 0.001)
    }

    // Unrelated SwiftUI/layout updates must not cancel the in-flight movement.
    host.layout()
    host.transition(to: state, animated: true)
    #expect(
        pages.layer?.animation(forKey: Shell.Host.animationKey)?.beginTime
            == pageAnimation.beginTime)
    state.pinned = true
    host.transition(to: state, animated: true)
    #expect(host.pages === pages && host.sidebar === sidebar)
    #expect(pages.frame.minX == 220)

    state.reduceMotion = true
    host.transition(to: state, animated: true)
    #expect(pages.layer?.animationKeys()?.isEmpty ?? true)
    #expect(sidebar.layer?.animationKeys()?.isEmpty ?? true)
}

@MainActor
@Test func floatingSidebarAndWindowResizeDoNotKeepStaleTransitions() {
    _ = NSApplication.shared
    typealias Shell = SidebarTransitionHost<Color, Color>
    var state = Shell.Configuration(
        pinned: false, revealed: false, edgeInset: 10, sidebarWidth: 220, reduceMotion: false)
    let host = Shell.Host(configuration: state, pages: .black, sidebar: .gray)
    host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    host.layout()
    let pageFrame = host.pages.frame
    state.revealed = true
    host.transition(to: state, animated: true)
    #expect(host.pages.frame == pageFrame)
    #expect(host.sidebar.frame.minX == 0)
    host.frame.size = NSSize(width: 1400, height: 900)
    host.layout()
    #expect(host.pages.frame == NSRect(x: 10, y: 10, width: 1380, height: 880))
    #expect(host.pages.layer?.animationKeys()?.isEmpty ?? true)
    #expect(host.sidebar.layer?.animationKeys()?.isEmpty ?? true)
}
