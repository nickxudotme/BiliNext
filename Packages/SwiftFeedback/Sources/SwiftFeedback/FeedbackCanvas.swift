import AppKit
import SwiftUI

struct FeedbackCanvas: NSViewRepresentable {
    @ObservedObject var session: FeedbackSession
    func makeNSView(context: Context) -> FeedbackCanvasView { FeedbackCanvasView(session: session) }
    func updateNSView(_ view: FeedbackCanvasView, context: Context) {
        view.session = session
        view.needsDisplay = true
    }
}

final class FeedbackCanvasView: NSView {
    var session: FeedbackSession
    private var hover: FeedbackElement?
    private var sceneNeedsRefresh = false
    private var activeStroke: [CGPoint] = []
    private var tracking: NSTrackingArea?
    private let ink = NSColor(calibratedRed: 0.02, green: 0.64, blue: 0.43, alpha: 1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: FeedbackSession) {
        self.session = session
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func resetCursorRects() {
        if session.phase == .annotating || session.phase == .drawing {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard session.phase == .annotating else { return }
        if sceneNeedsRefresh {
            session.refreshScene()
            sceneNeedsRefresh = false
        }
        let point = convert(event.locationInWindow, from: nil)
        let next = session.element(at: point)
        if next != hover {
            hover = next
            needsDisplay = true
        }
    }
    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard session.phase == .annotating, let source = session.sourceWindow,
            let content = source.contentView
        else { return }
        let screen = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        let sourcePoint = source.convertPoint(fromScreen: screen)
        let local = content.convert(sourcePoint, from: nil)
        if let target = content.hitTest(local) { target.scrollWheel(with: event) }
        hover = nil
        sceneNeedsRefresh = true
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard session.phase == .annotating || session.phase == .drawing else { return }
        window?.makeFirstResponder(self)
        activeStroke = [convert(event.locationInWindow, from: nil)]
        hover = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !activeStroke.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        if activeStroke.count < 2000 { activeStroke.append(point) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let first = activeStroke.first else { return }
        let last = convert(event.locationInWindow, from: nil)
        let travel = activeStroke.map { hypot($0.x - first.x, $0.y - first.y) }.max() ?? 0
        if travel >= 10 {
            activeStroke.append(last)
            session.addStroke(activeStroke)
        } else if session.phase == .annotating {
            session.select(at: last)
        }
        activeStroke = []
        needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) {
        activeStroke = []
        session.escape()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let phase = session.phase
        NSColor.black.withAlphaComponent(phase == .annotating || phase == .drawing ? 0.09 : 0.19)
            .setFill()
        bounds.fill()
        if let element = phase == .annotating
            ? hover : (session.pin == nil ? nil : session.selectedElement)
        {
            let path = NSBezierPath(
                roundedRect: element.frame.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            ink.withAlphaComponent(0.10).setFill()
            path.fill()
            ink.setStroke()
            path.lineWidth = 2
            path.stroke()
            if phase == .annotating {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let name = String(element.name.prefix(44)) as NSString
                let size = name.size(withAttributes: attributes)
                let label = CGRect(
                    x: max(
                        6,
                        min(bounds.width - size.width - 22, element.frame.midX - size.width / 2 - 8)
                    ),
                    y: element.frame.minY > 36 ? element.frame.minY - 29 : element.frame.maxY + 7,
                    width: size.width + 16, height: 23)
                ink.setFill()
                NSBezierPath(roundedRect: label, xRadius: 6, yRadius: 6).fill()
                name.draw(
                    at: CGPoint(x: label.minX + 8, y: label.minY + 4), withAttributes: attributes)
            }
        }
        for stroke in session.strokes { drawStroke(stroke.map(\.cgPoint)) }
        drawStroke(activeStroke)
        if let pin = session.pin {
            let p = pin.cgPoint
            let shape = NSBezierPath(
                ovalIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
            ink.setFill()
            shape.fill()
            NSColor.white.setStroke()
            shape.lineWidth = 2
            shape.stroke()
            ("1" as NSString).draw(
                at: CGPoint(x: p.x - 4, y: p.y - 8),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
        }
    }
    private func drawStroke(_ points: [CGPoint]) {
        guard let first = points.first, points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ink.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 7
        path.stroke()
        ink.setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
