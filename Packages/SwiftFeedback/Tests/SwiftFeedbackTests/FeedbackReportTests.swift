import AppKit
import ImageIO
import XCTest

@testable import SwiftFeedback

final class FeedbackReportTests: XCTestCase {
    func testReportPreservesContextEventsLogsAndBothImages() throws {
        try withTemporaryDirectory { directory in
            let context = makeContext()
            let event = FeedbackEvent(
                timestamp: context.capturedAt, name: "player.focus", fields: ["focused": "true"])
            let log = FeedbackLogEntry(
                timestamp: context.capturedAt, level: "error", subsystem: "test",
                category: "player",
                message: "测试诊断：按键未处理")
            let destination = try FeedbackReportWriter.write(
                directory: directory, context: context, events: [event], image: makeImage(),
                logs: [log])

            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
                Set([
                    "context.json", "events.json", "logs.json", "screenshot.png", "annotated.png",
                    "report.md",
                ]))
            let decoded: FeedbackReportContext = try decode("context.json", in: destination)
            XCTAssertEqual(decoded.schemaVersion, 1)
            XCTAssertEqual(decoded.capturedAt, context.capturedAt)
            XCTAssertEqual(decoded.description, context.description)
            XCTAssertEqual(decoded.environment, context.environment)
            XCTAssertEqual(decoded.application, context.application)
            XCTAssertEqual(decoded.selection, context.selection)
            XCTAssertEqual(decoded.selectedTarget?.file, "Demo/Player.swift")
            XCTAssertEqual(decoded.selectedTarget?.line, 42)
            XCTAssertEqual(decoded.targets.first?.semanticID, "player.controls")
            XCTAssertEqual(decoded.accessibility.first?.label, "播放")
            XCTAssertEqual(decoded.accessibility.first?.focused, true)
            XCTAssertEqual(decoded.diagnostics, ["测试采集诊断"])
            let events: [FeedbackEvent] = try decode("events.json", in: destination)
            XCTAssertEqual(events.first?.name, event.name)
            XCTAssertEqual(events.first?.fields, event.fields)
            let logs: [FeedbackLogEntry] = try decode("logs.json", in: destination)
            XCTAssertEqual(logs.first?.message, log.message)
            XCTAssertEqual(logs.first?.timestamp, log.timestamp)
            let report = try String(
                contentsOf: destination.appendingPathComponent("report.md"), encoding: .utf8)
            XCTAssertTrue(report.contains(context.description))
            XCTAssertTrue(report.contains("Demo/Player.swift:42"))
            XCTAssertTrue(report.contains("logs.json"))
            let raw = try loadBitmap("screenshot.png", in: destination)
            let annotated = try loadBitmap("annotated.png", in: destination)
            XCTAssertEqual(raw.pixelsWide, 200)
            XCTAssertEqual(raw.pixelsHigh, 160)
            XCTAssertEqual(annotated.pixelsWide, raw.pixelsWide)
            XCTAssertEqual(annotated.pixelsHigh, raw.pixelsHigh)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
    }

    func testAnnotationUsesTopLeftWindowPointsAndRetinaScale() throws {
        try withTemporaryDirectory { directory in
            let destination = try FeedbackReportWriter.write(
                directory: directory, context: makeContext(), events: [], image: makeImage())
            let original = try loadBitmap("screenshot.png", in: destination)
            let annotated = try loadBitmap("annotated.png", in: destination)
            var markedPixels: [(x: Int, y: Int)] = []
            for y in 0..<annotated.pixelsHigh {
                for x in 0..<annotated.pixelsWide {
                    let color = try XCTUnwrap(
                        annotated.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent > 0.8 && color.greenComponent < 0.4
                        && color.blueComponent < 0.4
                    {
                        markedPixels.append((x, y))
                    }
                }
            }
            // The 100 x 80 point window becomes 200 x 160 pixels. Its selection
            // begins at (10, 8) points, in the upper part of the screenshot.
            let minX = try XCTUnwrap(markedPixels.map(\.x).min())
            let maxX = try XCTUnwrap(markedPixels.map(\.x).max())
            let minY = try XCTUnwrap(markedPixels.map(\.y).min())
            let maxY = try XCTUnwrap(markedPixels.map(\.y).max())
            XCTAssertTrue((18...22).contains(minX), "Unexpected left border: \(minX)")
            XCTAssertTrue((58...62).contains(maxX), "Unexpected right border: \(maxX)")
            XCTAssertTrue(
                (14...18).contains(minY), "Expected a top-left origin; top border was \(minY)")
            XCTAssertTrue(
                (38...42).contains(maxY), "Expected a top-left origin; bottom border was \(maxY)")
            XCTAssertGreaterThan(
                try XCTUnwrap(original.colorAt(x: minX, y: minY)).greenComponent, 0.9)
            XCTAssertGreaterThan(try XCTUnwrap(annotated.colorAt(x: 40, y: 28)).greenComponent, 0.9)
            XCTAssertGreaterThan(
                try XCTUnwrap(annotated.colorAt(x: 20, y: 136)).greenComponent, 0.9)
        }
    }

    func testReportRemainsReadableWithoutScreenshot() throws {
        try withTemporaryDirectory { directory in
            let destination = try FeedbackReportWriter.write(
                directory: directory, context: makeContext(), events: [], image: nil)
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
                Set(["context.json", "events.json", "logs.json", "report.md"]))
            let context: FeedbackReportContext = try decode("context.json", in: destination)
            let events: [FeedbackEvent] = try decode("events.json", in: destination)
            let logs: [FeedbackLogEntry] = try decode("logs.json", in: destination)
            XCTAssertFalse(context.description.isEmpty)
            XCTAssertTrue(events.isEmpty)
            XCTAssertTrue(logs.isEmpty)
            let report = try String(
                contentsOf: destination.appendingPathComponent("report.md"), encoding: .utf8)
            XCTAssertTrue(report.contains("未获得，原因见采集诊断"))
            XCTAssertTrue(report.contains("测试采集诊断"))
        }
    }

    func testRecorderBoundsCapacityAndIndividualPayloads() {
        let recorder = FeedbackRecorder(capacity: 2)
        recorder.record("discarded")
        recorder.record("second")
        recorder.record(
            String(repeating: "n", count: 200),
            fields: ["details": String(repeating: "中", count: 1200)])
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.name, "second")
        XCTAssertEqual(snapshot.last?.name.count, 160)
        XCTAssertEqual(snapshot.last?.fields["details"]?.count, 1000)
        let minimum = FeedbackRecorder(capacity: 0)
        minimum.record("first")
        minimum.record("last")
        XCTAssertEqual(minimum.snapshot().map(\.name), ["last"])
    }

    func testRecorderSupportsConcurrentWritersAndSnapshots() {
        let capacity = 37
        let recorder = FeedbackRecorder(capacity: capacity)
        let failures = LockedFailures()
        DispatchQueue.concurrentPerform(iterations: 800) { index in
            recorder.record("event-\(index)", fields: ["index": String(index)])
            let snapshot = recorder.snapshot()
            if snapshot.count > capacity
                || Set(snapshot.map(\.name)).count != snapshot.count
                || snapshot.contains(where: {
                    $0.name != "event-\($0.fields["index"] ?? "missing")"
                })
            {
                failures.record()
            }
        }
        XCTAssertEqual(failures.count, 0)
        XCTAssertEqual(recorder.snapshot().count, capacity)
    }

    func testFreehandIsRenderedAsAStrokeAtItsOriginalWindowCoordinates() throws {
        try withTemporaryDirectory { directory in
            var context = makeContext()
            context.markup = FeedbackMarkup(
                kind: .drawing, pin: nil,
                strokes: [
                    [FeedbackPoint(CGPoint(x: 10, y: 8)), FeedbackPoint(CGPoint(x: 60, y: 20))]
                ],
                elementName: "圈画区域", elementRole: nil)
            let destination = try FeedbackReportWriter.write(
                directory: directory, context: context, events: [], image: makeImage())
            let bitmap = try loadBitmap("annotated.png", in: destination)
            let center = try XCTUnwrap(bitmap.colorAt(x: 70, y: 28)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(center.redComponent, 0.2)
            XCTAssertGreaterThan(center.greenComponent, 0.5)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 70, y: 132)).redComponent, 0.9)
        }
    }

    func testRecordingExportsFrameManifestOfflinePlayerAndTimelineTogether() throws {
        try withTemporaryDirectory { directory in
            let context = makeContext()
            let jpeg = try XCTUnwrap(
                NSBitmapImageRep(cgImage: makeImage()).representation(using: .jpeg, properties: [:])
            )
            let event = FeedbackEvent(
                timestamp: context.capturedAt, name: "recording.state",
                fields: ["workspace.menu": "首页"])
            let recording = FeedbackRecording(
                startedAt: context.capturedAt, duration: 1.2,
                frames: [.init(offset: 0, jpeg: jpeg), .init(offset: 1, jpeg: jpeg)],
                diagnostics: [], events: [event])
            let destination = try FeedbackReportWriter.write(
                directory: directory, context: context, events: recording.events, image: nil,
                recording: recording)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: destination.appendingPathComponent("recording.json")))
                    as? [String: Any])
            XCTAssertEqual(manifest["durationSeconds"] as? Double, 1.2)
            XCTAssertEqual(manifest["audio"] as? Bool, false)
            let frames = try XCTUnwrap(manifest["frames"] as? [[String: Any]])
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames.last?["offsetSeconds"] as? Double, 1)
            for frame in frames {
                let path = try XCTUnwrap(frame["file"] as? String)
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), jpeg)
            }
            let player = try String(
                contentsOf: destination.appendingPathComponent("replay.html"), encoding: .utf8)
            XCTAssertFalse(player.contains("__MANIFEST__"))
            XCTAssertFalse(player.contains("fetch("))
            XCTAssertTrue(player.contains("atob("))
            let events: [FeedbackEvent] = try decode("events.json", in: destination)
            XCTAssertEqual(events.first?.fields["workspace.menu"], "首页")
        }
    }

    private func makeContext() -> FeedbackReportContext {
        let selection = FeedbackRect(x: 10, y: 8, width: 20, height: 12)
        let target = FeedbackTargetSnapshot(
            id: "test-control", semanticID: "player.controls", label: "播放器控制栏",
            file: "Demo/Player.swift",
            line: 42, frame: selection)
        return FeedbackReportContext(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environment: [
                "feedback.windowWidth": "100", "feedback.windowHeight": "80",
                "app.name": "Test App",
            ],
            application: ["player.focused": "true", "tab.id": "fixture-tab"], targets: [target],
            accessibility: [
                AccessibilityNode(
                    role: "AXButton", label: "播放", value: nil, frame: selection, depth: 0,
                    identifier: "play", focused: true)
            ], diagnostics: ["测试采集诊断"], description: "空格键没有响应。\n请检查焦点状态。", selection: selection,
            selectedTarget: target)
    }

    private func makeImage() throws -> CGImage {
        let canvas = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        return try XCTUnwrap(canvas.makeImage())
    }

    private func loadBitmap(_ name: String, in directory: URL) throws -> NSBitmapImageRep {
        try XCTUnwrap(
            NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name))))
    }

    private func decode<T: Decodable>(_ name: String, in directory: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SwiftFeedbackTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
    }
}
