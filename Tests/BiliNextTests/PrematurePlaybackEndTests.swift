import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_LONG_PRELOAD_TEST"] == "1"))
func networkPreloadContinuesBeyondItsInitialVideoBuffer() async throws {
    // Anonymous playback in an independent muted core: no account/history reporter.
    let api = BilibiliAPI(restoreSession: false)
    let detail = try await api.detail("BV1iX3n6mELM")
    let page = try #require(detail.pages.first)
    let source = try await api.playback(bvid: detail.video.bvid, cid: page.cid)
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.isForeground = false
    core.speed = 3
    defer { core.stop() }
    try core.load(source, position: 0, autoplay: false)
    for _ in 0..<100 where !core.loaded || core.number("demuxer-cache-duration") < 10 {
        try await Task.sleep(for: .milliseconds(100))
    }
    let initialEnd = try #require(core.cacheSnapshot?.videoEnd)
    let target = max(initialEnd + 10, 90)
    try #require(core.loaded && core.failure == nil && target < core.duration)
    #expect(core.flag("pause") && core.time < 0.5)
    core.isForeground = true
    core.play()
    let deadline = ContinuousClock.now + .seconds(60)
    while core.time < target && core.failure == nil && !core.ended && ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(200))
    }
    #expect(core.failure == nil && core.playing && core.time >= target)
    #expect((core.cacheSnapshot?.videoEnd ?? 0) >= core.time)
    print(
        "Continued network preload: initial-video-end=\(initialEnd), played-to=\(core.time), video-cache-end=\(core.cacheSnapshot?.videoEnd ?? 0), decoder-drops=\(core.number("decoder-frame-drop-count"))"
    )
}

@MainActor
@Test func truncatedMediaDoesNotBecomeANormalPlaybackEnd() async throws {
    let fixture = try truncatedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.speed = 8
    defer { core.stop() }
    try core.load(
        Playback(
            url: fixture.short, quality: "test", qualityID: 80, qualities: [], videoStream: nil,
            audioStream: nil), position: 0, autoplay: false)
    for _ in 0..<100 where !core.loaded && core.failure == nil {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(core.cacheSnapshot?.eof == true && (core.cacheSnapshot?.videoEnd ?? 0) < 10)
    #expect(core.failure != nil, "A short read must reach recovery instead of normal completion")
    #expect(core.prematureEnd && !core.ended)
}

@MainActor
@Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
func truncatedDASHTrackRefreshesAndKeepsIntent(
    autoplay: Bool, scenario: (truncatedAudio: Bool, failedEvidence: Bool)
) async throws {
    let (truncatedAudio, failedEvidence) = scenario
    let fixture = try truncatedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let audio = fixture.folder.appendingPathComponent("audio.m4a")
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "20",
        "-c:a", "aac", "-movflags", "+faststart", audio.path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    #expect(encoder.terminationStatus == 0)
    let shortenedAudio = fixture.folder.appendingPathComponent("truncated-audio.m4a")
    let bytes = try Data(contentsOf: audio)
    try bytes.prefix(bytes.count / 3).write(to: shortenedAudio)
    func source(_ video: URL, audio: URL) -> Playback {
        Playback(
            url: video, quality: "test", qualityID: 80, qualities: [],
            videoStream: PlaybackStream(
                urls: [video], codec: "avc1", bandwidth: 100000,
                initialization: 0...1, index: 2...3),
            audioStream: PlaybackStream(
                urls: [audio], codec: "mp4a", bandwidth: 64000,
                initialization: 0...1, index: 2...3))
    }
    let fresh = source(fixture.full, audio: audio)
    var probes = 0
    var evidenceRefreshes = 0
    let core = try MPVPlayer(
        videoOutput: "null",
        sourceDuration: { url in
            probes += 1
            return failedEvidence && probes == 1 ? nil : await MediaSourceDuration.load(url)
        })
    core.refreshDurationProbeSources = {
        evidenceRefreshes += 1
        return (fixture.full, audio)
    }
    core.muted = true
    core.isForeground = false
    core.speed = 2
    var intent = false
    var position = 2.0
    var requests = 0
    var gate: CheckedContinuation<Playback, Never>?
    var phases: [String] = []
    let recovery = PlaybackRecovery(
        playback: source(
            truncatedAudio ? fixture.full : fixture.short,
            audio: truncatedAudio ? shortenedAudio : audio),
        fetch: { _ in
            requests += 1
            return await withCheckedContinuation { gate = $0 }
        },
        load: { value, _, phase in
            phases.append(phase)
            try core.load(
                value.playback, position: position, autoplay: intent,
                videoURL: value.video, audioURL: value.audio)
        }, onState: { _, _ in }, delay: { _ in })
    defer {
        gate?.resume(returning: fresh)
        recovery.cancel()
        core.onUpdate = nil
        core.stop()
    }
    core.onUpdate = { [weak core] time, _, _, _ in
        guard let core else { return }
        if let failure = core.failure {
            recovery.failed(
                code: core.failureCode, message: failure, refreshFirst: core.prematureEnd)
        } else if core.loaded {
            position = time
            recovery.loaded()
        }
    }
    try recovery.start()
    for _ in 0..<100 where gate == nil { try await Task.sleep(for: .milliseconds(30)) }
    let resume = try #require(gate)
    #expect(core.prematureEnd && core.flag("pause"))
    #expect(evidenceRefreshes == (failedEvidence ? 1 : 0))
    if truncatedAudio {
        #expect((core.cacheSnapshot?.audioEnd ?? 0) < 10)
        #expect((core.cacheSnapshot?.videoEnd ?? 0) > 19)
    } else {
        #expect((core.cacheSnapshot?.videoEnd ?? 0) < 10)
        #expect((core.cacheSnapshot?.audioEnd ?? 0) > 19)
    }
    intent = autoplay
    core.isForeground = true
    gate = nil
    resume.resume(returning: fresh)
    await recovery.waitForRecovery()
    for _ in 0..<100 where !core.loaded || core.failure != nil || recovery.recovering {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(core.loaded && core.failure == nil && !core.prematureEnd)
    #expect(requests == 1 && phases == ["initial", "refresh-after-eof"])
    #expect(core.flag("pause") == !autoplay && core.number("speed") == 2)
    #expect(core.time >= 1.9 && core.time < 5)
    #expect((core.cacheSnapshot?.videoEnd ?? 0) > 19)
    #expect((core.cacheSnapshot?.audioEnd ?? 0) > 19)
}

@MainActor
@Test func playbackEOFAwaitsTrackEvidenceBeforeNormalCompletion() async throws {
    let fixture = try truncatedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let audio = fixture.folder.appendingPathComponent("audio.m4a")
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "20",
        "-c:a", "aac", "-movflags", "+faststart", audio.path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    try #require(encoder.terminationStatus == 0)
    let source = Playback(
        url: fixture.short, quality: "test", qualityID: 80, qualities: [],
        videoStream: PlaybackStream(
            urls: [fixture.short], codec: "avc1", bandwidth: 100000,
            initialization: 0...1, index: 2...3),
        audioStream: PlaybackStream(
            urls: [audio], codec: "mp4a", bandwidth: 64000,
            initialization: 0...1, index: 2...3))
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    core.speed = 8
    var normalCompletions = 0
    core.onUpdate = { [weak core] _, _, _, _ in
        if core?.ended == true { normalCompletions += 1 }
    }
    defer { core.stop() }
    try core.load(source, position: 6, autoplay: true)
    for _ in 0..<100 where core.failure == nil {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(core.prematureEnd && core.failure != nil)
    #expect(normalCompletions == 0 && !core.ended)
}

@MainActor
@Test(arguments: ["audio", "video", "muxed-audio", "muxed-video"])
func completeShortTracksDoNotTriggerRecovery(track: String) async throws {
    let fixture = try truncatedFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let audio = fixture.folder.appendingPathComponent("complete-audio.m4a")
    let shortVideo = fixture.folder.appendingPathComponent("complete-video.mp4")
    let muxed = fixture.folder.appendingPathComponent("complete-muxed.mp4")
    func encode(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-v", "error"] + arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
    try encode([
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t",
        track.hasSuffix("video") ? "20" : "6", "-c:a", "aac", "-movflags", "+faststart", audio.path,
    ])
    try encode([
        "-i", fixture.full.path, "-t", "6", "-c", "copy", "-movflags", "+faststart",
        shortVideo.path,
    ])
    let video = track.hasSuffix("video") ? shortVideo : fixture.full
    try encode([
        "-i", video.path, "-i", audio.path, "-c", "copy", "-movflags", "+faststart",
        muxed.path,
    ])
    let isMuxed = track.hasPrefix("muxed-")
    let source = Playback(
        url: isMuxed ? muxed : video, quality: "test", qualityID: 80, qualities: [],
        videoStream: isMuxed
            ? nil
            : PlaybackStream(
                urls: [video], codec: "avc1", bandwidth: 100000, initialization: 0...1, index: 2...3
            ),
        audioStream: isMuxed
            ? nil
            : PlaybackStream(
                urls: [audio], codec: "mp4a", bandwidth: 64000, initialization: 0...1, index: 2...3)
    )
    let core = try MPVPlayer(videoOutput: "null")
    core.muted = true
    defer { core.stop() }
    try core.load(source, position: 0, autoplay: false)
    for _ in 0..<100 where !core.loaded || core.cacheSnapshot?.eof != true {
        try await Task.sleep(for: .milliseconds(30))
    }
    try await Task.sleep(for: .seconds(1))
    #expect(core.loaded && core.duration > 19 && core.cacheSnapshot?.eof == true)
    #expect(core.flag("pause") && core.failure == nil && !core.prematureEnd)
    if track.hasSuffix("video") {
        #expect((core.cacheSnapshot?.videoEnd ?? 0) < 7)
    } else {
        #expect((core.cacheSnapshot?.audioEnd ?? 0) < 7)
    }
    core.speed = 8
    core.play()
    let deadline = ContinuousClock.now + .seconds(5)
    while !core.ended, core.failure == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(core.ended && core.failure == nil && !core.prematureEnd)
}

@MainActor
@Test(arguments: [false, true])
func failedDurationProbeRefreshesEvidenceWithoutMisclassifyingShortTracks(completeShort: Bool)
    async throws
{
    let fixture = try durationEvidenceFixture(completeShort: completeShort)
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    var probes: [URL] = []
    var refreshes = 0
    let core = try MPVPlayer(
        videoOutput: "null",
        sourceDuration: { url in
            probes.append(url)
            return url == fixture.video ? nil : await MediaSourceDuration.load(url)
        })
    core.muted = true
    core.refreshDurationProbeSources = {
        refreshes += 1
        return (fixture.evidence, fixture.audio)
    }
    defer { core.stop() }
    try core.load(fixture.source, position: 0, autoplay: false)
    for _ in 0..<150
    where core.durationProbeAttempts < 2
        || core.sourceDurationSummary.contains("pending=true")
    {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(refreshes == 1 && probes == [fixture.video, fixture.evidence])
    #expect(core.prematureEnd == !completeShort)
    #expect((core.failure != nil) == !completeShort)
    #expect(core.flag("pause") && !core.ended)
}

@MainActor
@Test(arguments: [false, true])
func unknownDurationEvidenceIsBoundedAndDoesNotInventTruncation(refreshFails: Bool) async throws {
    let fixture = try durationEvidenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    var probes = 0
    var refreshes = 0
    let core = try MPVPlayer(
        videoOutput: "null",
        sourceDuration: { _ in
            probes += 1
            return nil
        })
    core.muted = true
    core.refreshDurationProbeSources = {
        refreshes += 1
        if refreshFails { throw MPVError(message: "offline") }
        return (fixture.evidence, fixture.audio)
    }
    defer { core.stop() }
    try core.load(fixture.source, position: 0, autoplay: false)
    for _ in 0..<150 where probes < 3 || core.sourceDurationSummary.contains("pending=true") {
        try await Task.sleep(for: .milliseconds(30))
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(probes == 3 && refreshes == 1)
    #expect(core.failure == nil && !core.prematureEnd)
    #expect(core.sourceDurationSummary.contains("pending=false"))
}

@MainActor
@Test(arguments: [false, true])
func replacedOrStoppedSourceRejectsLateDurationEvidence(stop: Bool) async throws {
    let fixture = try durationEvidenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    var gate: CheckedContinuation<(video: URL, audio: URL?), Error>?
    var probes = 0
    let core = try MPVPlayer(
        videoOutput: "null",
        sourceDuration: { _ in
            probes += 1
            return probes == 1 ? nil : 20
        })
    core.muted = true
    core.refreshDurationProbeSources = {
        try await withCheckedThrowingContinuation { gate = $0 }
    }
    defer { core.stop() }
    try core.load(fixture.source, position: 0, autoplay: false)
    for _ in 0..<100 where gate == nil {
        try await Task.sleep(for: .milliseconds(30))
    }
    let pending = try #require(gate)
    if stop {
        core.stop()
    } else {
        try core.load(
            Playback(
                url: fixture.evidence, quality: "test", qualityID: 80, qualities: [],
                videoStream: nil, audioStream: nil), position: 0, autoplay: false)
    }
    gate = nil
    pending.resume(returning: (fixture.evidence, fixture.audio))
    try await Task.sleep(for: .milliseconds(500))
    #expect(probes == 1 && core.durationProbeAttempts == 0)
    #expect(core.failure == nil && !core.prematureEnd)
    #expect(core.sourceDurationSummary.contains("video=unknown"))
}

private func durationEvidenceFixture(completeShort: Bool = false) throws -> (
    folder: URL, source: Playback, video: URL, evidence: URL, audio: URL
) {
    let fixture = try truncatedFixture()
    let short = fixture.folder.appendingPathComponent("complete-short.mp4")
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-i", fixture.full.path, "-t", "6", "-c", "copy",
        "-movflags", "+faststart", short.path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    try #require(encoder.terminationStatus == 0)
    let video = completeShort ? short : fixture.short
    let audio = fixture.folder.appendingPathComponent("audio.m4a")
    let audioEncoder = Process()
    audioEncoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    audioEncoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "20",
        "-c:a", "aac", "-movflags", "+faststart", audio.path,
    ]
    try audioEncoder.run()
    audioEncoder.waitUntilExit()
    try #require(audioEncoder.terminationStatus == 0)
    let source = Playback(
        url: video, quality: "test", qualityID: 80, qualities: [],
        videoStream: PlaybackStream(
            urls: [video], codec: "avc1", bandwidth: 100000, initialization: 0...1, index: 2...3),
        audioStream: PlaybackStream(
            urls: [audio], codec: "mp4a", bandwidth: 64000,
            initialization: 0...1, index: 2...3))
    let evidence = fixture.folder.appendingPathComponent("refreshed.mp4")
    try FileManager.default.copyItem(at: completeShort ? short : fixture.full, to: evidence)
    return (fixture.folder, source, video, evidence, audio)
}

private func truncatedFixture() throws -> (folder: URL, full: URL, short: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let full = folder.appendingPathComponent("full.mp4")
    let short = folder.appendingPathComponent("truncated.mp4")
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    encoder.arguments = [
        "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10", "-t", "20",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", full.path,
    ]
    try encoder.run()
    encoder.waitUntilExit()
    #expect(encoder.terminationStatus == 0)
    let bytes = try Data(contentsOf: full)
    try bytes.prefix(bytes.count / 3).write(to: short)
    return (folder, full, short)
}

@Test func prematureEndRequiresAFiniteKnownDurationAndAMeaningfulGap() {
    #expect(MPVPlayer.endedPrematurely(at: 71.1459, duration: 837.6847))
    #expect(!MPVPlayer.endedPrematurely(at: 837.6, duration: 837.6847))
    #expect(!MPVPlayer.endedPrematurely(at: 71, duration: 0))
    #expect(!MPVPlayer.endedPrematurely(at: 71, duration: .infinity))
    #expect(!MPVPlayer.endedPrematurely(at: .nan, duration: 838))
    #expect(!MPVPlayer.endedPrematurely(at: 0.95, duration: 1))
}
