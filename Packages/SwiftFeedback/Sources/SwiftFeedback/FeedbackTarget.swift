import AppKit
import SwiftUI

extension View {
    /// Registers this component's current visible frame and the modifier's source location.
    /// Pass `isActive: false` for retained pages hidden with SwiftUI opacity or other transitions.
    public func feedbackTarget(
        _ id: String, label: String? = nil, isActive: Bool = true,
        file: String = #fileID, line: UInt = #line
    ) -> some View {
        background {
            FeedbackTargetMarker(id: id, label: label, isActive: isActive, file: file, line: line)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct FeedbackTargetMarker: NSViewRepresentable {
    let id: String
    let label: String?
    let isActive: Bool
    let file: String
    let line: UInt

    func makeNSView(context: Context) -> FeedbackTargetMarkerView {
        let view = FeedbackTargetMarkerView()
        view.setAccessibilityElement(false)
        view.registration = FeedbackTargetRegistry.shared.register(
            view: view, id: id, label: label, isActive: isActive, file: file, line: line
        )
        return view
    }

    func updateNSView(_ view: FeedbackTargetMarkerView, context: Context) {
        guard let registration = view.registration else { return }
        FeedbackTargetRegistry.shared.update(
            registration, id: id, label: label, isActive: isActive, file: file, line: line
        )
    }

    static func dismantleNSView(_ view: FeedbackTargetMarkerView, coordinator: ()) {
        if let registration = view.registration {
            FeedbackTargetRegistry.shared.unregister(registration)
            view.registration = nil
        }
    }
}

private final class FeedbackTargetMarkerView: NSView {
    var registration: UUID?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
