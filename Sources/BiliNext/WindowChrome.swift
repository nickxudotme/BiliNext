import AppKit
import SwiftUI

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.configure() }
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
    }
}

struct TrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> Controls { Controls() }
    func updateNSView(_ view: Controls, context: Context) {}
    final class Controls: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .enumerated()
            {
                guard
                    let button = NSWindow.standardWindowButton(
                        kind, for: [.titled, .closable, .miniaturizable, .resizable])
                else { continue }
                button.setFrameOrigin(NSPoint(x: index * 20, y: 5))
                button.target = self
                button.action =
                    [
                        #selector(closeWindow), #selector(minimizeWindow),
                        #selector(fullscreenWindow),
                    ][index]
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
        @objc private func fullscreenWindow() { window?.toggleFullScreen(nil) }
    }
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
            onPosition(corridor.contains(point) ? point : nil)
        }
    }
}

// Include a narrow interior strip because a fullscreen pointer cannot travel
// past the left screen edge. The rest of the sidebar keeps an open drawer alive.
enum DrawerActivation {
    static func zone(x: CGFloat?, width: CGFloat, pinned: Bool) -> Int {
        guard let x, x >= -width else { return 0 }
        if x <= 3 { return 1 }
        return x <= width + (pinned ? 0 : 4) ? 2 : 0
    }
}
