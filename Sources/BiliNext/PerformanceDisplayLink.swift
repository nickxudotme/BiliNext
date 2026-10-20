import AppKit
import QuartzCore
import SwiftUI

struct PerformanceDisplayLink: NSViewRepresentable {
    let monitor: PerformanceMonitor
    func makeNSView(context: Context) -> Sensor { Sensor(monitor: monitor) }
    func updateNSView(_ view: Sensor, context: Context) {}
    static func dismantleNSView(_ view: Sensor, coordinator: ()) { view.stop() }

    final class Sensor: NSView {
        private weak var monitor: PerformanceMonitor?
        private var link: CADisplayLink?
        init(monitor: PerformanceMonitor) {
            self.monitor = monitor
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // Keep system-selected pacing; requesting 120Hz would change what we measure.
            let link = displayLink(target: self, selector: #selector(tick))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        func stop() {
            link?.invalidate()
            link = nil
            monitor?.reset()
        }
        @objc private func tick(_ link: CADisplayLink) {
            guard let window, window.isVisible, !window.isMiniaturized, NSApp.isActive else {
                monitor?.reset()
                return
            }
            monitor?.tick(link, screenMaximum: window.screen?.maximumFramesPerSecond ?? 0)
        }
    }
}
