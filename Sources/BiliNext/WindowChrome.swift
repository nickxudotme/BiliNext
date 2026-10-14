import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    var pinned = false
    var miniPlayer = false
    var onFullScreenChange: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onFullScreenChange = onFullScreenChange
        return view
    }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.onFullScreenChange = onFullScreenChange
        view.configure()
        view.apply(pinned: pinned, miniPlayer: miniPlayer)
    }
    final class ChromeView: NSView {
        var onFullScreenChange: (Bool) -> Void = { _ in }
        private var frameBeforeMiniPlayer: NSRect?

        /// 置顶 floats the window; 小窗 moves it to a 16:9 corner player and back again.
        func apply(pinned: Bool, miniPlayer: Bool) {
            guard let window else { return }
            let level: NSWindow.Level = pinned ? .floating : .normal
            if window.level != level { window.level = level }
            if miniPlayer, frameBeforeMiniPlayer == nil {
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                frameBeforeMiniPlayer = window.frame
                let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
                let size = NSSize(width: 480, height: 270)
                let frame = NSRect(
                    x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width,
                    height: size.height)
                DispatchQueue.main.async { window.setFrame(frame, display: true, animate: true) }
            } else if !miniPlayer, let previous = frameBeforeMiniPlayer {
                frameBeforeMiniPlayer = nil
                DispatchQueue.main.async { window.setFrame(previous, display: true, animate: true) }
            }
        }
        private var reportedFullScreen: Bool?
        private var notifications: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications = []
            if let window {
                for name in [
                    NSWindow.willEnterFullScreenNotification,
                    NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                ] {
                    notifications.append(
                        NotificationCenter.default.addObserver(
                            forName: name, object: window, queue: .main
                        ) { [weak self] notification in
                            MainActor.assumeIsolated {
                                self?.configure(
                                    fullScreen: notification.name
                                        != NSWindow.didExitFullScreenNotification)
                            }
                        })
                }
            }
            configure()
        }
        deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
        func configure(fullScreen: Bool? = nil) {
            guard let window else { return }
            let fullScreen = fullScreen ?? window.styleMask.contains(.fullScreen)
            if reportedFullScreen != fullScreen {
                reportedFullScreen = fullScreen
                DispatchQueue.main.async { [weak self] in
                    self?.onFullScreenChange(fullScreen)
                }
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

/// Wallpaper-tinted window backdrop; the pinned sidebar draws directly on it.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// A window-wide observer remains present while the drawer is hidden. Local
// events also cover child controls, where SwiftUI hover regions can lose events.
struct DrawerPointerTracker: NSViewRepresentable {
    var externalWidth: CGFloat
    var onPosition: (NSPoint?) -> Void
    func makeNSView(context: Context) -> Tracker { Tracker(onPosition: onPosition) }
    func updateNSView(_ view: Tracker, context: Context) {
        view.onPosition = onPosition
        view.externalWidth = externalWidth
    }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.stop() }
    final class Tracker: NSView {
        var onPosition: (NSPoint?) -> Void
        var externalWidth: CGFloat = 220
        private var monitor: Any?
        private var area: NSTrackingArea?
        private var timer: Timer?
        init(onPosition: @escaping (NSPoint?) -> Void) {
            self.onPosition = onPosition
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.samplePointer()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseMoved, .leftMouseDragged, .leftMouseDown,
            ]) { [weak self] event in
                guard let self else { return event }
                self.report(
                    event.window === self.window
                        ? self.convert(event.locationInWindow, from: nil) : nil)
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            timer?.invalidate()
            timer = nil
        }
        // Sampling also observes the position just outside the window, where
        // AppKit no longer delivers mouseMoved to this window.
        private func samplePointer() {
            guard let window, window.isKeyWindow, NSApp.isActive else {
                onPosition(nil)
                return
            }
            report(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self)
            addTrackingArea(next)
            area = next
        }
        override func mouseEntered(with event: NSEvent) {
            report(convert(event.locationInWindow, from: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            report(convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) {
            report(convert(event.locationInWindow, from: nil))
        }
        private func report(_ point: NSPoint?) {
            guard let point else {
                onPosition(nil)
                return
            }
            // Keep the drawer alive over the union of its interior and the
            // external drawer-width strip; top/bottom exits are outside this union.
            let corridor = NSRect(
                x: bounds.minX - externalWidth, y: bounds.minY,
                width: bounds.width + externalWidth, height: bounds.height)
            // y is reported as the distance from the top edge, where the window buttons sit.
            onPosition(
                corridor.contains(point)
                    ? NSPoint(x: point.x, y: isFlipped ? point.y : bounds.maxY - point.y) : nil)
        }
    }
}

// Include a narrow interior strip because a fullscreen pointer cannot travel
// past the left screen edge. As in Arc, resting in the top-left corner beside the
// window buttons also reveals the drawer. The rest of the sidebar keeps it alive.
enum DrawerActivation {
    static let cornerSize = CGSize(width: 96, height: 32)

    static func zone(x: CGFloat?, top: CGFloat? = nil, width: CGFloat, pinned: Bool) -> Int {
        guard let x, x >= -width else { return 0 }
        if x <= 3 { return 1 }
        if !pinned, let top, top >= 0, top <= cornerSize.height, x <= cornerSize.width {
            return 1
        }
        return x <= width + (pinned ? 0 : 4) ? 2 : 0
    }
}
