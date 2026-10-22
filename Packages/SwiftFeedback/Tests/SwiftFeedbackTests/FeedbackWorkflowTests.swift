import AppKit
import SwiftUI
import XCTest

@testable import SwiftFeedback

@MainActor
final class FeedbackWorkflowTests: XCTestCase {
    func testPinUsesAccessibleElementAndKeepsNearestSourceRegistration() throws {
        let (window, directory, session) = try makeSession()
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let button = NSButton(title: "刷新列表", target: nil, action: nil)
        button.frame = CGRect(x: 20, y: 30, width: 100, height: 30)
        window.contentView?.addSubview(button)
        let token = FeedbackTargetRegistry.shared.register(
            view: button, id: "list.refresh", file: "Fixture/List.swift", line: 27)
        defer { FeedbackTargetRegistry.shared.unregister(token) }
        session.select(at: CGPoint(x: 50, y: 150))
        XCTAssertEqual(session.phase, .composing)
        XCTAssertEqual(session.selectedElement?.source?.semanticID, "list.refresh")
        XCTAssertEqual(session.selectedElement?.source?.line, 27)
        XCTAssertNotNil(session.pin)
        XCTAssertTrue(session.strokes.isEmpty)
    }

    func testFreehandUndoRedoAndEscapeReturnToMarkupWithoutClosingFlow() throws {
        let (window, directory, session) = try makeSession()
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var closed = false
        session.close = { closed = true }
        session.addStroke([CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 50), CGPoint(x: 30, y: 80)])
        session.addStroke([CGPoint(x: 80, y: 20), CGPoint(x: 90, y: 80)])
        XCTAssertEqual(session.phase, .drawing)
        XCTAssertEqual(session.strokes.count, 2)
        session.undo()
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.redoStrokes.count, 1)
        session.redo()
        XCTAssertEqual(session.strokes.count, 2)
        session.escape()
        XCTAssertEqual(session.phase, .annotating)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertFalse(closed)
        session.escape()
        XCTAssertTrue(closed)
    }

    func testDefaultSubmissionSavesDirectlyAndPreservesFreehandPoints() async throws {
        let (window, directory, session) = try makeSession()
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        session.addStroke([CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 70)])
        session.description = "列表切换后位置丢失"
        session.toggleCategory(.bug)
        XCTAssertEqual(session.description, "列表切换后位置丢失")
        session.toggleCategory(.suggestion)
        XCTAssertEqual(session.category, .suggestion)
        XCTAssertEqual(session.description, "列表切换后位置丢失")
        session.toggleCategory(.suggestion)
        XCTAssertNil(session.category)
        session.toggleCategory(.bug)
        session.submit()
        XCTAssertEqual(session.phase, .saving)
        try await waitForReceipt(session)
        let url = try XCTUnwrap(session.savedURL)
        let json =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: url.appendingPathComponent("context.json")))
            as? [String: Any]
        XCTAssertEqual(json?["description"] as? String, "列表切换后位置丢失")
        XCTAssertEqual(json?["category"] as? String, "bug")
        let report = try String(contentsOf: url.appendingPathComponent("report.md"))
        XCTAssertTrue(report.contains("类型：🐛 出错"))
        let markup = try XCTUnwrap(json?["markup"] as? [String: Any])
        XCTAssertEqual(markup["kind"] as? String, "drawing")
        XCTAssertEqual((markup["strokes"] as? [[[String: Double]]])?.first?.last?["y"], 70)
        XCTAssertEqual((json?["conversation"] as? [[String: String]])?.count, 1)
        XCTAssertNil(session.question)
    }

    func testOptionalClarificationCanBeAnsweredOrSkippedAndPersistsConversation() async throws {
        let provider: FeedbackQuestionProvider = { _, _ in
            FeedbackQuestion(text: "切换前在哪个页面？", suggestions: ["动态", "收藏"])
        }
        let (window, directory, session) = try makeSession(provider: provider)
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        session.select(at: CGPoint(x: 40, y: 40))
        session.submit("切换标签后无法操作")
        XCTAssertEqual(session.phase, .clarifying)
        for _ in 0..<100 where session.question == nil { await Task.yield() }
        XCTAssertEqual(session.question?.suggestions, ["动态", "收藏"])
        session.finishAnswer("动态")
        try await waitForReceipt(session)
        XCTAssertEqual(session.conversation.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(session.conversation.last?.text, "动态")
    }

    func testCancelledPendingClarificationCannotWriteAReportLater() async throws {
        let provider: FeedbackQuestionProvider = { _, _ in
            try await Task.sleep(for: .seconds(1))
            return nil
        }
        let (window, directory, session) = try makeSession(provider: provider)
        defer {
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        session.select(at: CGPoint(x: 20, y: 20))
        session.submit("取消这条反馈")
        session.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(session.savedURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testNativeCanvasReceivesPointerInputAndCommitsAFreehandStroke() throws {
        let (window, directory, session) = try makeSession()
        let overlay = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: .borderless,
            backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        defer {
            session.cancel()
            overlay.close()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let host = NSHostingView(rootView: FeedbackEditor(session: session))
        overlay.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.isOpaque, "The annotation host must leave the actual app visible")
        func canvas(in view: NSView) -> FeedbackCanvasView? {
            if let result = view as? FeedbackCanvasView { return result }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        let surface = try XCTUnwrap(canvas(in: host))
        let hit = host.hitTest(CGPoint(x: 200, y: 350))
        XCTAssertTrue(
            hit === surface || hit?.isDescendant(of: surface) == true,
            "Blank-area hit went to \(String(describing: hit))")
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 1,
                    windowNumber: overlay.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 1))
        }
        surface.mouseDown(with: try event(.leftMouseDown, 100, 500))
        surface.mouseDragged(with: try event(.leftMouseDragged, 160, 450))
        surface.mouseDragged(with: try event(.leftMouseDragged, 120, 400))
        surface.mouseUp(with: try event(.leftMouseUp, 100, 500))
        XCTAssertEqual(session.phase, .drawing)
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertGreaterThan(session.strokes[0].count, 2)
        XCTAssertNil(session.pin)
        session.undo()
        XCTAssertTrue(session.strokes.isEmpty)
        session.redo()
        XCTAssertEqual(session.strokes.count, 1)
    }

    func testResizeKeepsDraftButClearsStaleGeometryAndPendingMarkup() throws {
        let (window, directory, session) = try makeSession()
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        session.addStroke([CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)])
        session.description = "保留这段问题说明"
        window.setContentSize(CGSize(width: 400, height: 250))
        session.windowResized()
        XCTAssertEqual(session.phase, .annotating)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertEqual(session.description, "保留这段问题说明")
        XCTAssertEqual(session.context.environment["feedback.windowWidth"], "400.0")
    }

    func testRecordingStateTimelineCapturesNavigationChangesWithoutRelyingOnMouseEvents() {
        let before = ["workspace.menu": "动态", "playback.time": "10", "old": "value"]
        let after = ["workspace.menu": "首页", "playback.time": "10"]
        XCTAssertEqual(
            FeedbackWindowRecording.changedState(from: before, to: after),
            ["workspace.menu": "首页", "old": "[removed]"])
        XCTAssertTrue(FeedbackWindowRecording.changedState(from: after, to: after).isEmpty)
    }

    func testGeometryChangeDuringCaptureNeverSavesMisalignedMarkupAndCanRestartWithDraft()
        async throws
    {
        let (window, directory, session) = try makeSession(metadata: [
            "screenshot.geometryChangedDuringCapture": "true"
        ])
        defer {
            session.cancel()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        session.select(at: CGPoint(x: 20, y: 20))
        session.submit("请保留这个问题说明")
        for _ in 0..<100 where session.phase != .failed { await Task.yield() }
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.savedURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        session.restartMarkup()
        XCTAssertEqual(session.phase, .annotating)
        XCTAssertEqual(session.description, "请保留这个问题说明")
        XCTAssertNil(session.pin)
    }

    private func waitForReceipt(_ session: FeedbackSession) async throws {
        for _ in 0..<200 {
            if session.phase == .receipt { return }
            if session.phase == .failed {
                XCTFail(session.error ?? "Save failed")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Report did not finish saving")
    }

    private func makeSession(
        provider: FeedbackQuestionProvider? = nil,
        metadata: [String: String] = ["screenshot.status": "fixture"]
    ) throws -> (
        NSWindow, URL, FeedbackSession
    ) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 50, y: 50, width: 300, height: 200), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FeedbackFlow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = FeedbackSession(
            window: window, directory: directory, contextProvider: { ["page": "fixture"] },
            questionProvider: provider,
            captureProvider: { _ in
                CapturedWindow(
                    image: nil, metadata: metadata, accessibility: [],
                    diagnostics: [])
            })
        return (window, directory, session)
    }
}
