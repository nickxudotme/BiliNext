import AppKit
import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@Test func subtitleEvidenceRequiresDifferentCuesAndResetsAfterSeek() {
    var evidence = SubtitleEvidence()
    for time in 0..<8 {
        #expect(
            evidence.observe(soft: "Hello, everyone!", hard: ["HELLO everyone"], time: Double(time))
                == .uncertain)
    }
    #expect(
        evidence.observe(soft: "Welcome to the channel", hard: ["Welcome to the channel"], time: 8)
            == .uncertain)
    #expect(
        evidence.observe(
            soft: "Today we learn about Swift", hard: ["Today we learn about Swift"], time: 12)
            == .duplicate)
    #expect(
        evidence.observe(soft: "Welcome to the channel", hard: ["Welcome to the channel"], time: 2)
            == .uncertain)
    #expect(!SubtitleEvidence.matches("We are looking at a beautiful sunset", "sunset"))
    #expect(!SubtitleEvidence.matches("你好", "你好"))
    #expect(SubtitleEvidence.matches("这是一段较长的中文字幕。", "这是一段较长的中文字幕"))
}

@Test func staticForeignSignDoesNotCountAsTranslatedSubtitles() {
    var evidence = SubtitleEvidence()
    for (index, soft) in [
        "Welcome to our new channel", "Today we are talking about the weather",
        "Thank you for watching this video",
    ].enumerated() {
        #expect(
            evidence.observe(soft: soft, hard: ["这是始终不变的中文广告标语"], time: Double(index * 4))
                == .uncertain)
    }
    var translated = SubtitleEvidence()
    let soft = [
        "Welcome to our new channel", "Today we are talking about the weather",
        "Thank you for watching this video",
    ]
    let hard = ["欢迎来到我们的新频道", "今天我们一起聊聊外面的天气", "明天太阳会照常升起"]
    for index in 0..<3 {
        #expect(
            translated.observe(soft: soft[index], hard: [hard[index]], time: Double(index * 4))
                == (index == 2 ? .differentLanguage : .uncertain))
    }
}

@MainActor
@Test func subtitleRulesPersistAndVideoOverridesChannelAndManualChoice() throws {
    let suite = "SmartSubtitleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SmartSubtitleModel(defaults: defaults)
    model.configure(video: "BVtest", cid: 1, owner: 123, track: "中文")
    model.channelRule = "hide"
    #expect(!model.visible)
    model.videoRule = "show"
    #expect(model.visible)
    model.setVisible(false)
    model.configure(video: "BVtest", cid: 1, owner: 123, track: "中文")
    #expect(!model.visible)  // Same playback context must respect the manual choice.
    model.redetect()
    #expect(model.visible)
    let restored = SmartSubtitleModel(defaults: defaults)
    restored.configure(video: "BVtest", cid: 1, owner: 123, track: "中文")
    #expect(restored.visible)
    restored.configure(video: "BVtest", cid: 2, owner: 123, track: "中文")
    #expect(!restored.visible)
    restored.channelRule = "auto"
    restored.enabled = false
    restored.setVisible(false)
    restored.configure(video: "BVnext", cid: 3, owner: nil, track: "中文")
    #expect(!restored.visible)
    #expect(!restored.hasChannel)
    restored.enabled = true
    #expect(restored.visible)
}

@MainActor
private func subtitleImage(_ text: String) throws -> NSBitmapImageRep {
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 1280 * 4, bitsPerPixel: 32))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.white,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(
        at: NSPoint(x: (1280 - size.width) / 2, y: 60), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor
@Test func localOCRReadsChineseAndEnglishVideoFrames() async throws {
    for text in ["这是一段较长的中文字幕", "Welcome to our new channel"] {
        let bitmap = try subtitleImage(text)
        let data = Data(
            bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let frame = SubtitleFrame(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, pixels: data)
        let hard = try await Task.detached { try HardSubtitleRecognizer.recognize(frame) }.value
        #expect(hard.contains { SubtitleEvidence.matches(text, $0) }, "OCR result: \(hard)")
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_SUBTITLE_TEST"] == "1"))
func rawMPVFramesDriveAutomaticSubtitleHidingAndRecovery() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let texts = [
        "Welcome to our new channel", "Today we learn about Swift",
        "Thank you for watching this video",
    ]
    for (index, text) in texts.enumerated() {
        let data = try #require(
            try subtitleImage(text).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(index).png"))
    }
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-framerate", "1/5", "-i", folder.appendingPathComponent("%d.png").path,
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "24",
        folder.appendingPathComponent("test.mp4").path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    #expect(encoder.terminationStatus == 0)
    let core = try MPVPlayer()
    let surface = try #require(MPVSurface.Surface(player: core))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView = surface
    window.orderFront(nil)
    defer {
        core.stop()
        surface.releaseRenderer()
        window.orderOut(nil)
    }
    let source = Playback(
        url: folder.appendingPathComponent("test.mp4"), quality: "test", qualityID: 80,
        qualities: [], videoStream: nil, audioStream: nil)
    try core.load(source, position: 0, autoplay: true)
    let suite = "SmartSubtitleIntegration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SmartSubtitleModel(defaults: defaults)
    model.configure(video: "BVfixture", cid: 1, owner: 1, track: "en")
    let cues = texts.enumerated().map {
        Cue(
            id: $0.offset, start: Double($0.offset * 5), end: Double(($0.offset + 1) * 5),
            text: $0.element)
    }
    for _ in 0..<80 {
        try await Task.sleep(for: .milliseconds(250))
        model.sample(player: core, cues: cues, time: core.time, active: core.playing)
        if !model.visible { break }
    }
    #expect(core.failure == nil)
    #expect(!model.visible)
    #expect(model.status.contains("重复字幕"))
    model.setVisible(true)
    #expect(model.visible)
    try await Task.sleep(for: .milliseconds(500))
    model.sample(player: core, cues: cues, time: core.time, active: true)
    #expect(!model.checking)
    core.seek(0)
    model.differentLanguage = "ask"
    let translated = ["欢迎来到我们的新频道", "今天我们一起学习苹果的编程语言", "谢谢大家观看今天的视频内容"]
    let translationCues = translated.enumerated().map {
        Cue(
            id: $0.offset, start: Double($0.offset * 5), end: Double(($0.offset + 1) * 5),
            text: $0.element)
    }
    try await Task.sleep(for: .milliseconds(500))
    for _ in 0..<80 {
        try await Task.sleep(for: .milliseconds(250))
        model.sample(player: core, cues: translationCues, time: core.time, active: core.playing)
        if model.needsDecision { break }
    }
    #expect(model.needsDecision)
    #expect(model.visible)
    model.resolveLanguage(keep: false)
    #expect(!model.visible && !model.needsDecision)
    model.resetAfterSeek()
    #expect(!model.visible)  // Manual decisions survive seeking.
}
