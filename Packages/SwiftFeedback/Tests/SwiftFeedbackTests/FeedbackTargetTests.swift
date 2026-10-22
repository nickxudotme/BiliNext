import AppKit
import SwiftUI
import XCTest

@testable import SwiftFeedback

@MainActor
final class FeedbackTargetTests: XCTestCase {
    func testNestedTargetHitTestingAndUnregisteredSpace() {
        let outer = target("outer", frame: CGRect(x: 10, y: 10, width: 200, height: 100))
        let inner = target("inner", frame: CGRect(x: 20, y: 20, width: 40, height: 30))

        XCTAssertEqual(
            FeedbackTargetSnapshot.hitTest(CGPoint(x: 30, y: 30), in: [outer, inner])?.id, "inner")
        XCTAssertEqual(
            FeedbackTargetSnapshot.hitTest(CGPoint(x: 100, y: 50), in: [inner, outer])?.id, "outer")
        XCTAssertNil(FeedbackTargetSnapshot.hitTest(CGPoint(x: 0, y: 0), in: [outer, inner]))
        XCTAssertNil(FeedbackTargetSnapshot.hitTest(CGPoint(x: 210, y: 110), in: [outer, inner]))
    }

    func testWindowCoordinatesAndClippingFollowLiveLayout() throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let registry = FeedbackTargetRegistry()
        let component = NSView(frame: CGRect(x: 180, y: 90, width: 80, height: 50))
        content.addSubview(component)
        registry.register(view: component, id: "clipped", file: "Example/Screen.swift", line: 42)

        let first = try XCTUnwrap(registry.snapshot(in: window).first)
        XCTAssertEqual(first.frame.cgRect, CGRect(x: 180, y: 0, width: 20, height: 30))
        XCTAssertEqual(first.file, "Example/Screen.swift")
        XCTAssertEqual(first.line, 42)

        component.frame = CGRect(x: 20, y: 30, width: 50, height: 40)
        let moved = try XCTUnwrap(registry.snapshot(in: window).first)
        XCTAssertEqual(moved.frame.cgRect, CGRect(x: 20, y: 50, width: 50, height: 40))
        XCTAssertEqual(moved.id, first.id)
    }

    func testActiveVisibilityAndExplicitUnregistration() throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let registry = FeedbackTargetRegistry()
        let component = NSView(frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        content.addSubview(component)
        let token = registry.register(view: component, id: "retained", isActive: false)
        XCTAssertTrue(registry.snapshot(in: window).isEmpty)

        registry.update(token, id: "retained", isActive: true)
        let first = try XCTUnwrap(registry.snapshot(in: window).first)
        XCTAssertEqual(first.id, token.uuidString)
        component.isHidden = true
        XCTAssertTrue(registry.snapshot(in: window).isEmpty)
        component.isHidden = false
        content.alphaValue = 0
        XCTAssertTrue(registry.snapshot(in: window).isEmpty)
        content.alphaValue = 1
        XCTAssertEqual(registry.snapshot(in: window).count, 1)
        registry.unregister(token)
        XCTAssertTrue(registry.snapshot(in: window).isEmpty)
    }

    func testRepeatedSemanticIDsKeepDistinctInstanceIDsAndReleasedViewsDisappear() throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let registry = FeedbackTargetRegistry()
        let second = NSView(frame: CGRect(x: 30, y: 0, width: 20, height: 20))
        content.addSubview(second)
        registry.register(view: second, id: "row")
        weak var weakFirst: NSView?
        autoreleasepool {
            let first = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
            weakFirst = first
            content.addSubview(first)
            registry.register(view: first, id: "row")
            let snapshots = registry.snapshot(in: window)
            XCTAssertEqual(snapshots.count, 2)
            XCTAssertNotEqual(snapshots[0].id, snapshots[1].id)
            first.removeFromSuperview()
        }
        XCTAssertNil(weakFirst)
        XCTAssertEqual(registry.snapshot(in: window).count, 1)
    }

    func testSwiftUIMarkerRecordsRegistrationSourceAndRealComponentBounds() throws {
        let window = makeWindow()
        defer { window.close() }
        let (sourceLine, component) = (UInt(#line), Color.clear.feedbackTarget("source"))
        let hosting = NSHostingView(rootView: component.frame(width: 80, height: 30))
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        window.contentView = hosting
        window.setContentSize(CGSize(width: 200, height: 120))
        hosting.layoutSubtreeIfNeeded()
        // Allow representable insertion/layout without displaying or activating a window.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hosting.layoutSubtreeIfNeeded()

        let snapshot = try XCTUnwrap(
            FeedbackTargetRegistry.shared.snapshot(in: window)
                .first { $0.semanticID == "source" }
        )
        XCTAssertTrue(snapshot.file.hasSuffix("FeedbackTargetTests.swift"))
        XCTAssertEqual(snapshot.line, sourceLine)
        XCTAssertEqual(snapshot.frame.width, 80, accuracy: 0.5)
        XCTAssertEqual(snapshot.frame.height, 30, accuracy: 0.5)
        XCTAssertEqual(snapshot.frame.x, 60, accuracy: 0.5)
        XCTAssertEqual(snapshot.frame.y, 45, accuracy: 0.5)
    }

    func testTitleBarIsIncludedInTopLeftCoordinates() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: .titled,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let component = NSView(frame: CGRect(x: 0, y: 100, width: 20, height: 20))
        content.addSubview(component)
        let registry = FeedbackTargetRegistry()
        registry.register(view: component, id: "top-of-content")
        let snapshot = try XCTUnwrap(registry.snapshot(in: window).first)
        let titleBarHeight = window.frame.height - content.bounds.height
        XCTAssertGreaterThan(titleBarHeight, 0)
        XCTAssertEqual(
            snapshot.frame.cgRect, CGRect(x: 0, y: titleBarHeight, width: 20, height: 20))
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func target(_ id: String, frame: CGRect) -> FeedbackTargetSnapshot {
        FeedbackTargetSnapshot(
            id: id, semanticID: id, label: id, file: "Example/Screen.swift", line: 10,
            frame: FeedbackRect(frame)
        )
    }
}
