import AVFoundation
import AppKit
import Foundation
import Testing

@testable import BiliNext

@Suite(.serialized)
struct ExperienceTests {
    @Test @MainActor func searchHistoryIsBoundedOrderedAndClearable() throws {
        let name = "BiliNext.SearchTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SearchHistoryStore(defaults: defaults)
        for index in 0..<25 { store.remember("term-\(index)") }
        store.remember("term-20")
        #expect(store.terms.count == 20 && store.terms.first == "term-20")
        #expect(SearchHistoryStore(defaults: defaults).terms == store.terms)
        store.clear()
        #expect(SearchHistoryStore(defaults: defaults).terms.isEmpty)
    }
    @Test func guideReceiptDoesNotRepeatAcrossLaunches() throws {
        let name = "BiliNext.GuideTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(GuideReceipt.claim(defaults: defaults))
        #expect(!GuideReceipt.claim(defaults: defaults))
    }
    @Test func downloadPublicationIsIdempotentAndPreservesExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("prepared.mp4")
        let destination = root.appendingPathComponent("video.mp4")
        try Data([1, 2, 3]).write(to: source)
        try Data([9, 8, 7]).write(to: destination)
        let checkpoint = try DownloadAssembler.fingerprint(source)
        let first = try DownloadAssembler.publish(
            source, destination: destination, checkpoint: checkpoint)
        let second = try DownloadAssembler.publish(
            source, destination: destination, checkpoint: checkpoint)
        #expect(first == second && first != destination)
        #expect(try Data(contentsOf: destination) == Data([9, 8, 7]))
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func downloadedTracksMergeAndCheckpointDetectsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        let audio = root.appendingPathComponent("audio.m4a")
        let output = root.appendingPathComponent("prepared.mp4")
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=2", "-f",
            "lavfi", "-i", "sine=frequency=440:duration=2", "-map", "0:v", "-c:v", "libx264",
            video.path, "-map", "1:a", "-c:a", "aac", audio.path,
        ]
        try encoder.run()
        encoder.waitUntilExit()
        #expect(encoder.terminationStatus == 0)
        let checkpoint = try await DownloadAssembler.prepare(
            video: video, audio: audio, output: output)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try DownloadAssembler.restore(output)?.digest == checkpoint.digest)
        let player = try await MainActor.run { () throws -> MPVPlayer in
            let player = try MPVPlayer(videoOutput: "null")
            player.muted = true
            try player.loadFile(output)
            return player
        }
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { player.time < 0.3 && player.failure == nil }),
            Date() < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        await MainActor.run {
            #expect(player.time >= 0.3 && player.duration > 1 && player.failure == nil)
            player.stop()
        }

        try Data([0]).write(to: output)
        #expect(try DownloadAssembler.restore(output) == nil)
    }
    @Test @MainActor func pendingDownloadsRestorePausedWithoutStartingNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("downloads.json")
        let records = [
            DownloadRecord(
                id: UUID(), bvid: "BV1234567890", cid: 1, title: "test", state: "下载中", progress: 0.4
            )
        ]
        try JSONEncoder().encode(records).write(to: file)
        let manager = DownloadManager(store: file)
        #expect(manager.items.count == 1 && manager.items[0].state == "已暂停")
        #expect(manager.items[0].progress == 0.4)
    }
    @Test @MainActor func emptyDanmakuStopsClockEvenWhileVideoIsPlaying() {
        _ = NSApplication.shared
        let surface = DanmakuSurface.Surface(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(
            contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = surface
        surface.running = true
        surface.render(time: 10)
        #expect(surface.displayLink?.isPaused == true)
        surface.stopClock()
    }
}
