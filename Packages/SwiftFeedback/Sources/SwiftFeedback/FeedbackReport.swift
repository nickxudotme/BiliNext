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
                let recordingMetadata: [String: Any] = [
                    "format": "window-frame-sequence-v1",
                    "startedAt": formatter.string(from: recording.startedAt),
                    "durationSeconds": recording.duration, "sampleRateLimit": "1 frame/second",
                    "frames": frameIndex, "diagnostics": recording.diagnostics,
                    "eventsFile": "events.json", "audio": false,
                    "timeline": events.map { event -> [String: Any] in
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
                let html = Self.replayHTML.replacingOccurrences(
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
    private static let replayHTML = """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>操作录制</title>
        <style>body{margin:0;background:#17191b;color:#eee;font:14px system-ui;padding:24px}main{max-width:1080px;margin:auto}img{width:100%;max-height:75vh;object-fit:contain;background:#000}input{width:100%;accent-color:#059669}p{color:#aaa}header{display:flex;justify-content:space-between}button{padding:7px 14px}pre{white-space:pre-wrap}</style>
        <main><header><h2>操作录制</h2><button id="play">播放</button></header><img id="frame" alt="录制的窗口画面"><input id="time" type="range" min="0" step="1" value="0" aria-label="录制时间线"><p id="label"></p><pre id="events"></pre><p>每秒最多一帧窗口画面，不包含音频。真实操作事件见 events.json。</p></main>
        <script>const m=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__MANIFEST__'),c=>c.charCodeAt(0))));const t=document.getElementById('time'),f=document.getElementById('frame'),l=document.getElementById('label'),b=document.getElementById('play');t.max=Math.max(0,m.frames.length-1);function show(){const x=m.frames[+t.value];if(x){f.src=x.file;l.textContent=x.offsetSeconds.toFixed(1)+' / '+m.durationSeconds.toFixed(1)+' 秒';document.getElementById('events').textContent=(m.timeline||[]).filter(e=>e.offsetSeconds<=x.offsetSeconds).slice(-5).map(e=>e.offsetSeconds.toFixed(2)+'s '+e.name+' '+JSON.stringify(e.fields)).join('\\n')}else{l.textContent='未取得窗口画面，操作事件仍已保存。'}}t.oninput=show;let timer;b.onclick=()=>{if(timer){clearInterval(timer);timer=null;b.textContent='播放';return}b.textContent='暂停';timer=setInterval(()=>{if(+t.value>=+t.max){clearInterval(timer);timer=null;b.textContent='播放';return}t.value=+t.value+1;show()},1000)};show();</script></html>
        """

}
