import AppKit
import QuartzCore
import SwiftUI
import os

/// Commit page layout once, then move both retained hosting roots on the same
/// compositor timeline. No animation progress is published into the page tree.
struct SidebarTransitionHost<Pages: View, Sidebar: View>: NSViewRepresentable {
    struct Configuration: Equatable {
        var pinned: Bool
        var revealed: Bool
        var edgeInset: CGFloat
        var sidebarWidth: CGFloat
        var reduceMotion: Bool
    }

    let configuration: Configuration
    let pages: Pages
    let sidebar: Sidebar

    func makeNSView(context: Context) -> Host {
        Host(configuration: configuration, pages: pages, sidebar: sidebar)
    }

    func updateNSView(_ view: Host, context: Context) {
        view.pages.rootView = pages
        view.sidebar.rootView = sidebar
        view.transition(to: configuration, animated: view.window != nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Host: NSView {
        static var animationKey: String { "sidebarTransition" }
        let pages: NSHostingView<Pages>
        let sidebar: NSHostingView<Sidebar>
        private var configuration: Configuration
        private var laidOutBounds: NSRect?
        private var applyingGeometry = false
        private let signposter = OSSignposter(
            subsystem: "me.nickxu.BiliNext", category: "SidebarTransition")

        override var isFlipped: Bool { true }

        init(configuration: Configuration, pages: Pages, sidebar: Sidebar) {
            self.configuration = configuration
            self.pages = NSHostingView(rootView: pages)
            self.sidebar = NSHostingView(rootView: sidebar)
            super.init(frame: .zero)
            wantsLayer = true
            for view in [self.pages as NSView, self.sidebar] {
                view.wantsLayer = true
                addSubview(view)
            }
            self.pages.sizingOptions = []
            self.sidebar.sizingOptions = []
            self.pages.safeAreaRegions = []
            self.sidebar.safeAreaRegions = []
            // Previews extend beyond the sidebar and do not accept input.
            self.sidebar.clipsToBounds = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            guard !applyingGeometry, laidOutBounds != bounds else { return }
            // A window resize/fullscreen change supersedes the sidebar transition.
            applyGeometry(animated: false)
        }

        func transition(to next: Configuration, animated: Bool) {
            let previous = configuration
            configuration = next
            guard previous != next || laidOutBounds != bounds else { return }
            let visibilityChanged =
                previous.pinned != next.pinned || previous.revealed != next.revealed
            let stableViewport =
                laidOutBounds == bounds && previous.edgeInset == next.edgeInset
                && previous.sidebarWidth == next.sidebarWidth
            applyGeometry(
                animated: animated && visibilityChanged && stableViewport && !next.reduceMotion)
        }

        private func applyGeometry(animated: Bool) {
            guard !applyingGeometry else { return }
            applyingGeometry = true
            defer { applyingGeometry = false }
            laidOutBounds = bounds
            let c = configuration
            let interval = signposter.beginInterval("SidebarLayout", "pinned=\(c.pinned)")
            defer { signposter.endInterval("SidebarLayout", interval) }
            let leading = c.pinned ? c.sidebarWidth : c.edgeInset
            let pageFrame = NSRect(
                x: leading, y: c.edgeInset,
                width: max(0, bounds.width - leading - c.edgeInset),
                height: max(0, bounds.height - 2 * c.edgeInset))
            let visible = c.pinned || c.revealed
            // While pinned changes, the sidebar's trailing edge and the page's
            // leading edge follow the same displacement (including in fullscreen).
            let sidebarFrame = NSRect(
                x: visible ? 0 : c.edgeInset - c.sidebarWidth, y: 0,
                width: c.sidebarWidth + 4, height: bounds.height)
            let views: [NSView] = [pages, sidebar]
            let starts = views.map { view -> LayerState? in
                guard let layer = view.layer else { return nil }
                return LayerState(layer.presentation() ?? layer)
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for view in views { view.layer?.removeAnimation(forKey: Self.animationKey) }
            if pages.frame != pageFrame { pages.frame = pageFrame }
            if sidebar.frame != sidebarFrame { sidebar.frame = sidebarFrame }
            sidebar.alphaValue = visible ? 1 : 0
            // Resolve the destination only once, before the shared start time.
            pages.layoutSubtreeIfNeeded()
            sidebar.layoutSubtreeIfNeeded()
            if animated {
                let startTime = CACurrentMediaTime()
                for (view, start) in zip(views, starts) {
                    guard let layer = view.layer, let start else { continue }
                    let end = LayerState(layer)
                    let group = CAAnimationGroup()
                    group.animations = [
                        animation("position", from: start.position, to: end.position),
                        animation("bounds", from: start.bounds, to: end.bounds),
                        animation("opacity", from: start.opacity, to: end.opacity),
                    ]
                    group.duration = Motion.panelDuration
                    group.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.25, 0.46, 0.45, 0.94)
                    group.beginTime = layer.convertTime(startTime, from: nil)
                    layer.add(group, forKey: Self.animationKey)
                }
            }
            CATransaction.commit()
            // Model geometry already equals the target. Core Animation removes
            // each group itself; no stale completion can overwrite a newer toggle.
        }

        private func animation(_ key: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Motion.panelDuration
            return animation
        }

        private struct LayerState {
            let position: CGPoint
            let bounds: CGRect
            let opacity: Float

            init(_ layer: CALayer) {
                position = layer.position
                bounds = layer.bounds
                opacity = layer.opacity
            }
        }
    }
}
