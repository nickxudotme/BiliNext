import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct FeedbackEvent: Codable, Sendable {
    public let timestamp: Date
    public let name: String
    public let fields: [String: String]
}

/// Bounded, thread-safe breadcrumbs. Recording never publishes SwiftUI state.
public final class FeedbackRecorder: @unchecked Sendable {
    public static let shared = FeedbackRecorder()
    private let lock = NSLock()
    private var events: [FeedbackEvent] = []
    private let capacity: Int

    public init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    public func record(_ name: String, fields: [String: String] = [:]) {
        let event = FeedbackEvent(
            timestamp: Date(), name: String(name.prefix(160)),
            fields: fields.mapValues { String($0.prefix(1000)) })
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func snapshot() -> [FeedbackEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

struct FeedbackReportContext: Codable, Sendable {
    var schemaVersion = 1
    let capturedAt: Date
    let environment: [String: String]
    let application: [String: String]
    let targets: [FeedbackTargetSnapshot]
    let accessibility: [AccessibilityNode]
    let diagnostics: [String]
    let description: String
    let selection: FeedbackRect?
    let selectedTarget: FeedbackTargetSnapshot?
    var markup: FeedbackMarkup? = nil
    var conversation: [FeedbackConversationMessage] = []
    var category: FeedbackCategory? = nil
}

enum FeedbackReportWriter {
    static func write(
        directory: URL, context: FeedbackReportContext, events: [FeedbackEvent],
        image: CGImage?, logs: [FeedbackLogEntry] = [], recording: FeedbackRecording? = nil
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: context.capturedAt).replacingOccurrences(
            of: ":", with: "-")
        let destination = directory.appendingPathComponent(
            "\(stamp)-\(UUID().uuidString.prefix(8))")
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(context).write(to: staging.appendingPathComponent("context.json"))
            try encoder.encode(events).write(to: staging.appendingPathComponent("events.json"))
            try encoder.encode(logs).write(to: staging.appendingPathComponent("logs.json"))
            if let image {
                try png(image, to: staging.appendingPathComponent("screenshot.png"))
                let annotated = annotate(
                    image, selection: context.selection, environment: context.environment,
                    markup: context.markup)
                try png(annotated, to: staging.appendingPathComponent("annotated.png"))
            }
            if let recording {
                let framesDirectory = staging.appendingPathComponent("recording")
                try fm.createDirectory(at: framesDirectory, withIntermediateDirectories: false)
                var frameIndex: [[String: Any]] = []
                for (index, frame) in recording.frames.enumerated() {
                    let name = String(format: "frame-%03d.jpg", index)
                    try frame.jpeg.write(to: framesDirectory.appendingPathComponent(name))
                    frameIndex.append(["offsetSeconds": frame.offset, "file": "recording/" + name])
                }
                let logEvents = logs.filter {
                    $0.timestamp >= recording.startedAt
                        && $0.timestamp
                            <= recording.startedAt.addingTimeInterval(recording.duration)
                }.map {
                    FeedbackEvent(
                        timestamp: $0.timestamp, name: "log." + $0.level,
                        fields: [
                            "message": $0.message, "category": $0.category,
                            "subsystem": $0.subsystem,
                        ])
                }
                let timeline = (events + logEvents).sorted { $0.timestamp < $1.timestamp }
                let recordingMetadata: [String: Any] = [
                    "format": "window-frame-sequence-v1",
                    "startedAt": formatter.string(from: recording.startedAt),
                    "durationSeconds": recording.duration, "sampleRateLimit": "1 frame/second",
                    "frames": frameIndex, "diagnostics": recording.diagnostics,
                    "eventsFile": "events.json", "audio": false,
                    "timeline": timeline.map { event -> [String: Any] in
                        [
                            "offsetSeconds": event.timestamp.timeIntervalSince(recording.startedAt),
                            "name": event.name, "fields": event.fields,
                        ]
                    },
                ]
                try JSONSerialization.data(
                    withJSONObject: recordingMetadata, options: [.prettyPrinted, .sortedKeys]
                )
                .write(to: staging.appendingPathComponent("recording.json"))
                let manifest = try JSONSerialization.data(
                    withJSONObject: recordingMetadata, options: [.sortedKeys])
                let html = FeedbackReplayHTML.content.replacingOccurrences(
                    of: "__MANIFEST__", with: manifest.base64EncodedString())
                try Data(html.utf8).write(to: staging.appendingPathComponent("replay.html"))
            }
            let target =
                context.selectedTarget.map {
                    "\($0.label) (`\($0.semanticID)`)\n\n源码注册点：`\($0.file):\($0.line)`"
                } ?? "未选择已注册组件；请结合截图、区域坐标和可访问性树定位。"
            let report = """
                # 界面反馈

                \(context.description)

                ## 目标

                \(target)

                ## 现场

                - 采集时间：\(formatter.string(from: context.capturedAt))
                - 应用：\(context.environment["app.name"] ?? "")
                - 类型：\(context.category?.title ?? "未分类")
                - 截图：\(image == nil ? "未获得，原因见采集诊断" : "screenshot.png；标注见 annotated.png")
                - 已注册区域：\(context.targets.count)
                - 可访问性节点：\(context.accessibility.count)
                - 最近事件：\(events.count)，见 events.json
                - 最近进程日志：\(logs.count)，见 logs.json
                - 完整运行状态、窗口与环境：context.json

                ## 补充说明

                \(context.conversation.map { "**" + $0.role + "**: " + $0.text }.joined(separator: "\n\n"))

                ## 操作录制

                \(recording == nil ? "未录制操作。" : "录制信息见 recording.json；窗口画面见 recording/。打开 replay.html 可拖动预览，events.json 提供真实操作时间线。每秒最多一帧，不包含音频。")

                ## 采集诊断

                \(context.diagnostics.map { "- " + $0 }.joined(separator: "\n"))

                源码位置是当前构建的注册点，未必是缺陷发生处；请先核对构建信息和现有代码。截图与状态按需采集，不是确定性回放。此报告仅保存在本机。
                """
            try Data(report.utf8).write(to: staging.appendingPathComponent("report.md"))
            try fm.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func png(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func annotate(
        _ image: CGImage, selection: FeedbackRect?, environment: [String: String],
        markup: FeedbackMarkup? = nil
    ) -> CGImage {
        guard selection != nil || markup != nil,
            let width = Double(environment["feedback.windowWidth"] ?? ""), width > 0,
            let height = Double(environment["feedback.windowHeight"] ?? ""), height > 0,
            let canvas = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let sx = Double(image.width) / width
        let sy = Double(image.height) / height
        if let markup {
            canvas.setStrokeColor(CGColor(red: 0.02, green: 0.64, blue: 0.43, alpha: 1))
            canvas.setFillColor(CGColor(red: 0.02, green: 0.64, blue: 0.43, alpha: 1))
            canvas.setLineWidth(max(3, 3 * sx))
            canvas.setLineCap(.round)
            canvas.setLineJoin(.round)
            for stroke in markup.strokes {
                guard let first = stroke.first else { continue }
                canvas.move(to: CGPoint(x: first.x * sx, y: Double(image.height) - first.y * sy))
                for point in stroke.dropFirst() {
                    canvas.addLine(
                        to: CGPoint(x: point.x * sx, y: Double(image.height) - point.y * sy))
                }
                canvas.strokePath()
            }
            if let point = markup.pin {
                if let selection {
                    canvas.stroke(
                        CGRect(
                            x: selection.x * sx,
                            y: Double(image.height) - (selection.y + selection.height) * sy,
                            width: selection.width * sx, height: selection.height * sy))
                }
                canvas.fillEllipse(
                    in: CGRect(
                        x: (point.x - 8) * sx,
                        y: Double(image.height) - (point.y + 8) * sy, width: 16 * sx,
                        height: 16 * sy))
            }
            return canvas.makeImage() ?? image
        }
        guard let selection else { return image }
        let rect = CGRect(
            x: selection.x * sx, y: Double(image.height) - (selection.y + selection.height) * sy,
            width: selection.width * sx, height: selection.height * sy)
        canvas.setStrokeColor(CGColor(red: 1, green: 0.18, blue: 0.15, alpha: 1))
        canvas.setLineWidth(max(3, 2 * sx))
        canvas.stroke(rect.insetBy(dx: 1, dy: 1))
        return canvas.makeImage() ?? image
    }
}
