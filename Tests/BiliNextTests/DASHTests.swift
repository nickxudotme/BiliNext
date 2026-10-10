import AVFoundation
import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

private func indexFixture(version: UInt8 = 0, hierarchical: Bool = false) -> Data {
    var body = Data([version, 0, 0, 0])
    func append(_ value: UInt64, width: Int = 4) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            body.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
    append(1)
    append(1000)
    append(0, width: version == 0 ? 4 : 8)
    append(10, width: version == 0 ? 4 : 8)
    append(2)
    append(hierarchical ? 0x8000_0064 : 100)
    append(2000)
    append(0x9000_0000)
    append(200)
    append(1500)
    append(0x9000_0000)
    let size = UInt32(body.count + 8)
    var data = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
    data.append(Data("sidx".utf8))
    data.append(body)
    return data
}

@Test func dashIndexLocatesFragmentsAndBuildsVODPlaylist() throws {
    for version: UInt8 in [0, 1] {
        let bytes = indexFixture(version: version)
        let index = try DASHIndex(data: bytes, offset: 700)
        let start = Int64(700 + bytes.count + 10)
        #expect(
            index.fragments.map(\.range) == [start...(start + 99), (start + 100)...(start + 299)])
        #expect(index.fragments.map(\.duration) == [2, 1.5])
        let playlist = index.playlist(initializationPath: "video/init.mp4") { "video/\($0).m4s" }
        #expect(playlist.contains("#EXT-X-TARGETDURATION:2"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"video/init.mp4\""))
        #expect(playlist.contains("#EXTINF:1.500000,\nvideo/1.m4s"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }
}

@Test func dashIndexRejectsTruncationAndNestedReferences() {
    #expect(throws: (any Error).self) { try DASHIndex(data: indexFixture().dropLast(), offset: 0) }
    #expect(throws: (any Error).self) {
        try DASHIndex(data: indexFixture(hierarchical: true), offset: 0)
    }
    #expect(throws: (any Error).self) { try DASHIndex(data: Data(), offset: 0) }
}

// Opt-in, read-only and muted. Uses no account unless separately requested via AUTH_PLAYBACK.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_DASH_TEST"] == "1"))
@MainActor func nativeDASHPlaybackSmoke() async throws {
    let authenticated = ProcessInfo.processInfo.environment["BILINEXT_AUTH_PLAYBACK"] == "1"
    #if DEBUG
        let api = BilibiliAPI(restoreSession: authenticated, credentialStorage: .developmentFile)
    #else
        let api = BilibiliAPI(restoreSession: authenticated)
    #endif
    if authenticated { _ = try await api.profile() }
    var bvid = ProcessInfo.processInfo.environment["BILINEXT_TEST_BVID"] ?? "BV1xx411c7mD"
    let require4K = ProcessInfo.processInfo.environment["BILINEXT_4K_TEST"] == "1"
    let requireAV1 = ProcessInfo.processInfo.environment["BILINEXT_AV1_TEST"] == "1"
    if requireAV1 { #expect(MediaCapabilities.hardwareAV1) }
    if require4K {
        let results = try await api.search("4K 风景")
        var found: String?
        for video in results.prefix(8) {
            let detail = try await api.detail(video.bvid)
            guard let page = detail.pages.first else { continue }
            let source = try await api.playback(bvid: video.bvid, cid: page.cid, quality: 120)
            if source.qualityID == 120
                && (!requireAV1 || source.videoStream?.codec.hasPrefix("av01.") == true)
            {
                found = video.bvid
                break
            }
        }
        bvid = try #require(found, "搜索结果中未找到实际下发的 4K 流")
    }
    let detail = try await api.detail(bvid)
    let page = try #require(detail.pages.first)
    let playback = try await api.playback(bvid: bvid, cid: page.cid, quality: 127)
    #expect(playback.videoStream != nil)
    if requireAV1 { #expect(playback.videoStream?.codec.hasPrefix("av01.") == true) }
    let (loader, item) = try await DASHResourceLoader.prepare(playback)
    defer { loader.invalidate() }
    let player = AVPlayer(playerItem: item)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output)
    player.isMuted = true
    defer {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    player.play()
    for _ in 0..<150 {
        if player.currentTime().seconds > 2 || item.status == .failed { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    if let error = item.error { throw error }
    #expect(item.status == .readyToPlay)
    #expect(player.currentTime().seconds > 2)
    if playback.audioStream != nil {
        #expect(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio })
    }
    let frame = try #require(
        output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil))
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    if require4K { #expect(max(width, height) >= 3840) }
    let duration = item.duration.seconds
    #expect(duration.isFinite && duration > 10)
    let target = min(30, duration / 2)
    #expect(
        await player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero))
    player.playImmediately(atRate: 1.5)
    try await Task.sleep(for: .seconds(3))
    #expect(player.currentTime().seconds > target + 1)
    player.pause()
    let position = player.currentTime().seconds
    try await Task.sleep(for: .milliseconds(500))
    #expect(abs(player.currentTime().seconds - position) < 0.1)
    print(
        "DASH smoke: bvid=\(bvid), codec=\(playback.videoStream?.codec ?? "MP4"), quality=\(playback.qualityID), decoded=\(width)x\(height), duration=\(Int(duration)), seek/rate/pause passed; muted"
    )
    if require4K {
        let lower = try await api.playback(bvid: bvid, cid: page.cid, quality: 64)
        let (lowerLoader, lowerItem) = try await DASHResourceLoader.prepare(lower)
        defer { lowerLoader.invalidate() }
        player.replaceCurrentItem(with: lowerItem)
        #expect(await player.seek(to: CMTime(seconds: position, preferredTimescale: 600)))
        #expect(player.rate == 0)
        #expect(abs(player.currentTime().seconds - position) < 0.2)
        player.playImmediately(atRate: 1.5)
        for _ in 0..<100 {
            if player.currentTime().seconds > position + 1 || lowerItem.status == .failed { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        if let error = lowerItem.error { throw error }
        #expect(player.currentTime().seconds > position + 1)
        print(
            "DASH switch: 4K → \(lower.qualityID), position and paused state preserved, resumed at 1.5x; muted"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(sessionStore: SessionStore(directory: directory))
        model.player.isMuted = true
        model.open(Video(bvid: bvid, title: "4K 播放验证"))
        defer { model.close(bvid) }
        for _ in 0..<200 {
            if model.player.currentTime().seconds > 1 || model.playerError != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(model.playerError == nil)
        #expect(model.playing)
        model.selectQuality(120)
        for _ in 0..<200 {
            if !model.videoLoading { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(model.playerError == nil)
        #expect(model.qualityID == 120)
        model.player.pause()
        model.selectQuality(64)
        for _ in 0..<200 {
            if !model.videoLoading { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(model.playerError == nil)
        #expect(model.qualityID == 64)
        #expect(model.player.rate == 0)
        model.player.play()
        model.selectQuality(120)
        model.selectQuality(80)
        for _ in 0..<200 {
            if !model.videoLoading { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(model.playerError == nil)
        #expect(model.qualityID == 80)
        #expect(model.player.rate > 0)
        print("AppModel: autoplay, 4K selection, paused switch, rapid replacement passed; muted")
        if requireAV1 {
            #expect(model.playbackCodec.hasPrefix("av01."))
            let failedItem = AVPlayerItem(
                url: directory.appendingPathComponent("missing-media.mp4"))
            let source = try await api.playback(bvid: bvid, cid: page.cid, quality: 80)
            model.observeMediaStatus(failedItem, playback: source)
            model.player.replaceCurrentItem(with: failedItem)
            model.player.play()
            for _ in 0..<250 {
                if !model.videoLoading, !model.playbackCodec.hasPrefix("av01."),
                    model.player.currentItem?.status == .readyToPlay
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(model.playerError == nil)
            #expect(!model.playbackCodec.hasPrefix("av01."))
            #expect(model.player.currentItem?.status == .readyToPlay)
            #expect(model.player.rate > 0)
            print(
                "Runtime codec fallback: failed AV1 item → \(model.playbackCodec), playback resumed; muted"
            )
            model.togglePlayback()
            let failedHEVC = AVPlayerItem(url: directory.appendingPathComponent("missing-hevc.mp4"))
            let hevcSource = try await api.playback(
                bvid: bvid, cid: page.cid, quality: 80, allowAV1: false)
            model.observeMediaStatus(failedHEVC, playback: hevcSource)
            model.player.replaceCurrentItem(with: failedHEVC)
            for _ in 0..<250 {
                if !model.videoLoading, model.playbackCodec.hasPrefix("avc1"),
                    model.player.currentItem?.status == .readyToPlay
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(model.playerError == nil)
            #expect(model.playbackCodec.hasPrefix("avc1"))
            #expect(model.player.currentItem?.status == .readyToPlay)
            #expect(model.player.rate == 0)
            print("Runtime codec fallback: failed HEVC item → H.264, paused state preserved; muted")
            let avc = try await api.playback(
                bvid: bvid, cid: page.cid, quality: 120,
                allowAV1: false, allowHEVC: false)
            #expect(avc.videoStream?.codec.hasPrefix("avc1") == true)
            let (avcLoader, avcItem) = try await DASHResourceLoader.prepare(avc)
            defer { avcLoader.invalidate() }
            player.replaceCurrentItem(with: avcItem)
            player.play()
            for _ in 0..<150 {
                if player.currentTime().seconds > 1 || avcItem.status == .failed { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(avcItem.status == .readyToPlay)
            #expect(player.currentTime().seconds > 1)
            print("Explicit H.264 fallback: quality=\(avc.qualityID), playing; muted")
        }
    }
}
