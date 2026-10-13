import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

private func recoveryFixture(
    _ codec: String = "av01.0.08M.08", urls: [String] = ["primary", "backup"]
) throws -> Playback {
    let videos = try urls.map {
        try #require(URL(string: "https://\($0).example/video?token=secret"))
    }
    let audio = try #require(URL(string: "https://audio.example/audio?token=secret"))
    return Playback(
        url: try #require(videos.first), quality: "1080P", qualityID: 80,
        qualities: [PlaybackQuality(value: 80, label: "1080P")],
        videoStream: PlaybackStream(
            urls: videos, codec: codec, bandwidth: 2_000_000, initialization: 0...3, index: 4...7),
        audioStream: PlaybackStream(
            urls: [audio], codec: "mp4a.40.2", bandwidth: 128000, initialization: 0...3,
            index: 4...7))
}

@MainActor
@Test func recoveryDeduplicatesFailureAndRotatesSources() async throws {
    var loads: [String] = []
    var requests = 0
    let fixture = try recoveryFixture(urls: ["primary", "primary", "backup"])
    let recovery = PlaybackRecovery(
        playback: fixture,
        fetch: { _ in
            requests += 1
            return fixture
        },
        load: { source, _, _ in loads.append(source.video.host ?? "") }, onState: { _, _ in },
        delay: { _ in await Task.yield() })
    try recovery.start()
    recovery.failed(code: -13, message: "loading failed")
    recovery.failed(code: -13, message: "same polling error")
    await recovery.waitForRecovery()
    #expect(loads == ["primary.example", "backup.example"])
    #expect(requests == 0)
}

@MainActor
@Test func recoveryRefreshesThenDisablesFailedCodecsWithinBudget() async throws {
    let av1 = try recoveryFixture(urls: ["av1"])
    let hevc = try recoveryFixture("hev1.1.6.L120", urls: ["hevc"])
    let avc = try recoveryFixture("avc1.640028", urls: ["avc"])
    let mp4 = Playback(
        url: try #require(URL(string: "https://mp4.example/file")), quality: "1080P", qualityID: 80,
        qualities: [], videoStream: nil, audioStream: nil)
    var options: [PlaybackRecovery.Options] = []
    var loads: [String] = []
    var errors: [String] = []
    let recovery = PlaybackRecovery(
        playback: av1,
        fetch: { value in
            options.append(value)
            if !value.preferDASH { return mp4 }
            if !value.allowHEVC { return avc }
            if !value.allowAV1 { return hevc }
            return av1
        }, load: { source, _, _ in loads.append(source.video.host ?? "") },
        onState: { _, error in if let error { errors.append(error) } }, delay: { _ in })
    try recovery.start()
    for _ in 0..<4 {
        recovery.failed(code: -17, message: "format failure")
        await recovery.waitForRecovery()
    }
    #expect(loads == ["av1.example", "hevc.example", "avc.example", "mp4.example"])
    #expect(options.map(\.allowAV1) == [false, false, false])
    #expect(errors.count == 1)
}

@MainActor
@Test func recoveryBudgetAndPermissionFailuresAreTerminal() async throws {
    let fixture = try recoveryFixture(urls: ["one", "two", "three", "four"])
    var loads = 0
    var errors = 0
    let recovery = PlaybackRecovery(
        playback: fixture, limit: 3,
        fetch: { _ in
            Issue.record("Budget should stop before refetch")
            return fixture
        },
        load: { _, _, _ in loads += 1 }, onState: { _, error in if error != nil { errors += 1 } },
        delay: { _ in })
    try recovery.start()
    for _ in 0..<8 {
        recovery.failed(code: -13, message: "offline")
        await recovery.waitForRecovery()
    }
    #expect(loads == 3)
    #expect(errors == 1)

    let single = try recoveryFixture(urls: ["only"])
    var calls = 0
    var permissionError: String?
    let denied = PlaybackRecovery(
        playback: single,
        fetch: { _ in
            calls += 1
            throw APIError(code: -101, message: "expired account")
        },
        load: { _, _, _ in }, onState: { _, error in permissionError = error }, delay: { _ in })
    try denied.start()
    denied.failed(code: -13, message: "loading failed")
    await denied.waitForRecovery()
    #expect(calls == 1)
    #expect(permissionError?.contains("登录") == true)
    #expect(denied.cancelled)
}

@MainActor
@Test func replacedRecoveryRejectsLateResponseAndUsesCurrentPlaybackIntent() async throws {
    let fixture = try recoveryFixture(urls: ["only"])
    let refreshed = try recoveryFixture(urls: ["fresh"])
    var continuation: CheckedContinuation<Playback, Never>?
    var positions: [Double] = []
    var intentions: [Bool] = []
    var position = 42.0
    var playing = true
    let recovery = PlaybackRecovery(
        playback: fixture,
        fetch: { _ in await withCheckedContinuation { continuation = $0 } },
        load: { _, _, _ in
            positions.append(position)
            intentions.append(playing)
        },
        onState: { _, _ in }, delay: { _ in })
    try recovery.start()
    recovery.failed(code: -13, message: "expired URL")
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    let resume = try #require(continuation)
    playing = false
    position = 90
    resume.resume(returning: refreshed)
    await recovery.waitForRecovery()
    #expect(positions == [42, 90])
    #expect(intentions == [true, false])

    continuation = nil
    recovery.failed(code: -13, message: "next failure")
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    let late = try #require(continuation)
    let pending = Task { await recovery.waitForRecovery() }
    recovery.cancel()
    late.resume(returning: refreshed)
    await pending.value
    #expect(positions.count == 2)
}

@MainActor
@Test func playbackDiagnosticsExcludeSignedURLs() throws {
    let fixture = try recoveryFixture()
    let context = PlaybackDiagnosticContext(
        session: UUID(), requestedQuality: 112,
        source: PlaybackRecovery.Source(
            playback: fixture, video: fixture.url, audio: fixture.audioStream?.urls.first),
        attempt: 2, phase: "alternate-source")
    #expect(context.summary.contains("quality=112/80"))
    #expect(context.summary.contains("video-bps=2000000"))
    #expect(context.summary.contains("primary.example"))
    #expect(!context.summary.contains("secret"))
    #expect(!context.summary.contains("token="))
}

@MainActor
@Test func realMPVRecoversFromMissingFileAndPreservesPausedPosition() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("fixture.mp4")
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ffmpeg.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=10", "-t", "8", "-an", "-c:v",
        "libx264", "-pix_fmt", "yuv420p", video.path,
    ]
    try ffmpeg.run()
    ffmpeg.waitUntilExit()
    #expect(ffmpeg.terminationStatus == 0)
    let missing = directory.appendingPathComponent("missing.mp4")
    let source = Playback(
        url: missing, quality: "fixture", qualityID: 80, qualities: [],
        videoStream: PlaybackStream(
            urls: [missing, video], codec: "avc1", bandwidth: 1000, initialization: 0...1,
            index: 2...3), audioStream: nil)
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.speed = 1.5
    defer { core.stop() }
    var loads: [URL] = []
    var error: String?
    let recovery = PlaybackRecovery(
        playback: source,
        fetch: { _ in
            Issue.record("Backup should load without refetch")
            return source
        },
        load: { candidate, _, _ in
            loads.append(candidate.video)
            try core.load(
                candidate.playback, position: 2, autoplay: false, videoURL: candidate.video)
        }, onState: { _, failure in if let failure { error = failure } }, delay: { _ in })
    core.onUpdate = { [weak core] _, _, _, _ in
        guard let core else { return }
        if let failure = core.failure {
            recovery.failed(code: core.failureCode, message: failure)
        } else if core.loaded {
            recovery.loaded()
        }
    }
    try recovery.start()
    for _ in 0..<80 {
        if core.loaded && core.failure == nil || error != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(loads == [missing, video])
    #expect(error == nil)
    #expect(core.loaded)
    #expect(core.failure == nil)
    #expect(core.flag("pause"))
    #expect(abs(core.time - 2) < 0.2)
    #expect(core.number("speed") == 1.5)
    // Queue a superseded failure before a valid replacement. Old END_FILE must not poison it.
    try core.load(source, position: 0, autoplay: false, videoURL: missing)
    try core.load(source, position: 3, autoplay: false, videoURL: video)
    for _ in 0..<50 {
        if core.loaded && core.failure == nil && abs(core.time - 3) < 0.2 { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(core.failure == nil)
    #expect(abs(core.time - 3) < 0.2)
    recovery.cancel()
}
