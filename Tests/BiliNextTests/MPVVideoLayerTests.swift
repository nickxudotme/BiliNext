import AppKit
import Foundation
import ImageIO
import Testing

@testable import BiliNext
@testable import BiliNextCore

/// The main thread must never wait for the render queue: the queue flushes Core Animation
/// transactions, so waiting on it from inside a main-thread commit deadlocks the app.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func videoLayerNeverBlocksTheMainThreadOnItsRenderQueue() async throws {
    let player = try MPVPlayer()
    let layer = try #require(MPVVideoLayer(handle: player.handle))
    let gate = DispatchSemaphore(value: 0)
    layer.renderQueue.async { gate.wait() }

    let start = Date()
    layer.display()
    layer.releaseRenderer(keepingAlive: player)
    #expect(Date().timeIntervalSince(start) < 0.5)

    gate.signal()
    await withCheckedContinuation { done in layer.renderQueue.async { done.resume() } }
}

/// Real libmpv in a real window: a paused frame stays drawn while the window resizes, now that
/// resize redraws are forwarded to the render queue instead of drawn on the main thread.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_MPV_TEST"] == "1"))
func pausedVideoRedrawsAcrossResizes() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=4",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", folder.appendingPathComponent("test.mp4").path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    #expect(encoder.terminationStatus == 0)

    let core = try MPVPlayer()
    core.muted = true
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
    try core.load(
        Playback(
            url: folder.appendingPathComponent("test.mp4"), quality: "test", qualityID: 80,
            qualities: [], videoStream: nil, audioStream: nil),
        position: 1, autoplay: false)

    /// The share of sampled pixels in the window's middle that are not black, read from a
    /// capture of the window as the compositor shows it.
    func lit() throws -> Double {
        let file = folder.appendingPathComponent("\(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let data = image.dataProvider?.data as Data?
        else { return 0 }
        let channels = image.bitsPerPixel / 8
        var bright = 0
        var total = 0
        for y in stride(from: image.height / 4, to: image.height * 3 / 4, by: 8) {
            for x in stride(from: image.width / 4, to: image.width * 3 / 4, by: 8) {
                let offset = y * image.bytesPerRow + x * channels
                let sum = Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
                if sum > 60 { bright += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(bright) / Double(total)
    }

    for _ in 0..<50 where try lit() < 0.3 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(try lit() > 0.3)
    for size in [NSSize(width: 900, height: 506), NSSize(width: 480, height: 270)] {
        window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try lit() > 0.3, "frame missing after resizing to \(size)")
    }
}
