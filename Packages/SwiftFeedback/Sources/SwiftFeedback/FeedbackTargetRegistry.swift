import AppKit
import Foundation

/// A component's registration site and its currently visible rectangle, in points
/// measured from the top-left corner of the complete window (including its title bar).
public struct FeedbackTargetSnapshot: Codable, Sendable, Identifiable {
    public let id: String
    public let semanticID: String
    public let label: String
    public let file: String
    public let line: UInt
    public let frame: FeedbackRect

    public init(
        id: String, semanticID: String, label: String, file: String, line: UInt,
        frame: FeedbackRect
    ) {
        self.id = id
        self.semanticID = semanticID
        self.label = label
        self.file = file
        self.line = line
        self.frame = frame
    }

    /// The smallest registered component beneath a point. Unregistered space has no target.
    /// The point uses the same complete-window, top-left coordinate system as `frame`.
    public static func hitTest(_ point: CGPoint, in snapshots: [Self]) -> Self? {
        snapshots.filter { $0.frame.cgRect.contains(point) }.min { lhs, rhs in
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            return lhsArea == rhsArea ? lhs.id < rhs.id : lhsArea < rhsArea
        }
    }
}

/// Registration does not observe layout or publish SwiftUI state. Geometry is read
/// only when a report is requested, and registered views are held weakly.
@MainActor
public final class FeedbackTargetRegistry {
    public static let shared = FeedbackTargetRegistry()

    private final class Registration {
        weak var view: NSView?
        var semanticID: String
        var label: String
        var isActive: Bool
        var file: String
        var line: UInt

        init(view: NSView, id: String, label: String?, isActive: Bool, file: String, line: UInt) {
            self.view = view
            semanticID = id
            self.label = label ?? id
            self.isActive = isActive
            self.file = file
            self.line = line
        }
    }

    private var registrations: [UUID: Registration] = [:]

    public init() {}

    /// Registers an AppKit view. Retain the returned token to update or remove it.
    /// `file` and `line` describe this registration site, not an inferred implementation site.
    @discardableResult
    public func register(
        view: NSView, id: String, label: String? = nil, isActive: Bool = true,
        file: String = #fileID, line: UInt = #line
    ) -> UUID {
        removeReleasedViews()
        let token = UUID()
        registrations[token] = Registration(
            view: view, id: id, label: label, isActive: isActive, file: file, line: line
        )
        return token
    }

    /// Updates metadata without changing the instance identifier or observing layout.
    public func update(
        _ token: UUID, id: String, label: String? = nil, isActive: Bool = true,
        file: String = #fileID, line: UInt = #line
    ) {
        guard let registration = registrations[token] else { return }
        registration.semanticID = id
        registration.label = label ?? id
        registration.isActive = isActive
        registration.file = file
        registration.line = line
    }

    public func unregister(_ token: UUID) {
        registrations.removeValue(forKey: token)
    }

    public func snapshot(in window: NSWindow) -> [FeedbackTargetSnapshot] {
        removeReleasedViews()
        let windowBounds = CGRect(origin: .zero, size: window.frame.size)
        return registrations.compactMap { token, registration in
            guard registration.isActive,
                let view = registration.view,
                view.window === window,
                !view.isHiddenOrHasHiddenAncestor,
                hasVisibleAlpha(view)
            else { return nil }

            // visibleRect accounts for clipping by ancestor views, including scroll views.
            let visibleBounds = view.visibleRect.intersection(view.bounds)
            guard !visibleBounds.isEmpty, !visibleBounds.isNull else { return nil }
            let windowRect = view.convert(visibleBounds, to: nil).intersection(windowBounds)
            guard !windowRect.isEmpty, !windowRect.isNull else { return nil }
            let topLeftRect = CGRect(
                x: windowRect.minX, y: windowBounds.height - windowRect.maxY,
                width: windowRect.width, height: windowRect.height
            )
            return FeedbackTargetSnapshot(
                id: token.uuidString, semanticID: registration.semanticID,
                label: registration.label, file: registration.file, line: registration.line,
                frame: FeedbackRect(topLeftRect)
            )
        }.sorted { lhs, rhs in
            lhs.semanticID == rhs.semanticID ? lhs.id < rhs.id : lhs.semanticID < rhs.semanticID
        }
    }

    private func removeReleasedViews() {
        registrations = registrations.filter { $0.value.view != nil }
    }

    private func hasVisibleAlpha(_ view: NSView) -> Bool {
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return true
    }
}
