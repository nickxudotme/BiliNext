import AppKit
import BiliNextCore
import CMPV
import OpenGL.GL3
import SwiftUI
import os

/// One libmpv instance per retained playback tab; preview remains a separate muted AVPlayer.
@MainActor
final class MPVPlayer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.nickxu.BiliNext",
        category: "PlaybackRecovery")
    let handle: OpaquePointer
    private var poll: Timer?
    private(set) var pollInterval = 0.0
    var isForeground = true {
        didSet { if oldValue != isForeground { updatePolling() } }
    }
    private struct Snapshot: Equatable {
        let time: Double
        let duration: Double
        let playing: Bool
        let buffering: Bool
        let loaded: Bool
        let ended: Bool
        let failure: String?
    }
    private var lastUpdate: Snapshot?
    private enum SourceTrack: String { case video, audio }
    private var trackSources: [SourceTrack: URL] = [:]
    private var trackDurations: [SourceTrack: Double] = [:]
    private var durationProbe: Task<Void, Never>?
    private var probedTracks = Set<SourceTrack>()
    private var sourceGeneration = UUID()
    struct CacheSnapshot {
        let eof: Bool
        let end: Double?
        let videoEnd: Double?
        let audioEnd: Double?
    }

    /// This node property does not implement slash-delimited subproperties.
    var cacheSnapshot: CacheSnapshot? {
        var root = mpv_node()
        guard mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &root) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&root) }
        func field(_ node: mpv_node, _ key: String) -> mpv_node? {
            guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else { return nil }
            for index in 0..<Int(list.pointee.num) {
                if let name = list.pointee.keys[index], String(cString: name) == key {
                    return list.pointee.values[index]
                }
            }
            return nil
        }
        func number(_ node: mpv_node?) -> Double? {
            guard let node, node.format == MPV_FORMAT_DOUBLE, node.u.double_.isFinite else {
                return nil
            }
            return node.u.double_
        }
        var videoEnd: Double?
        var audioEnd: Double?
        if let streams = field(root, "ts-per-stream"), streams.format == MPV_FORMAT_NODE_ARRAY,
            let list = streams.u.list
        {
            for index in 0..<Int(list.pointee.num) {
                let stream = list.pointee.values[index]
                guard let type = field(stream, "type"), type.format == MPV_FORMAT_STRING,
                    let name = type.u.string
                else { continue }
                switch String(cString: name) {
                case "video": videoEnd = number(field(stream, "cache-end"))
                case "audio": audioEnd = number(field(stream, "cache-end"))
                default: break
                }
            }
        }
        let eof = field(root, "eof-cached")
        return CacheSnapshot(
            eof: eof?.format == MPV_FORMAT_FLAG && eof?.u.flag != 0,
            end: number(field(root, "cache-end")), videoEnd: videoEnd, audioEnd: audioEnd)
    }
    private let playbackActivity = PlaybackActivity()
    private(set) var loaded = false
    private(set) var failure: String?
    private(set) var failureCode: Int32?
    private(set) var prematureEnd = false
    private(set) var diagnosticContext: PlaybackDiagnosticContext?
    private var commandSequence: UInt64 = 0
    private var loadCommandID: UInt64 = 0
    private var entryID: Int64?
    private var waitingForStart = false
    private var reported = false
    private var wasCachePaused = false
    var captureVideoFrame: (() async -> SubtitleFrame?)?
    var onUpdate: ((Double, Double, Bool, Bool) -> Void)?
    var time: Double { number("time-pos") }
    var duration: Double { number("duration") }
    var playing: Bool { loaded && failure == nil && !flag("pause") && !flag("eof-reached") }
    /// Playback reached the end; keep-open holds the last frame.
    var ended: Bool {
        loaded && failure == nil && durationProbe == nil && flag("eof-reached")
    }
    var volume: Double {
        get { number("volume") / 100 }
        set { set("volume", String(max(0, min(1, newValue)) * 100)) }
    }
    var muted: Bool {
        get { flag("mute") }
        set { set("mute", newValue ? "yes" : "no") }
    }
    var speed = 1.0 {
        didSet {
            applyBufferPolicy()
            set("speed", String(speed))
        }
    }
    init(videoOutput: String = "libmpv") throws {
        guard let core = mpv_create() else { throw MPVError(message: "无法创建 mpv 播放器") }
        handle = core
        let options = [
            "config": "no", "terminal": "no", "vo": videoOutput, "hwdec": "videotoolbox",
            "idle": "yes", "keep-open": "yes", "pause": "yes", "osc": "no",
            "input-default-bindings": "no", "load-scripts": "no", "sub-auto": "no",
            "cache": "yes", "cache-secs": "20", "demuxer-max-bytes": "134217728",
            "demuxer-readahead-secs": "20", "demuxer-max-back-bytes": "16777216",
            // Start as soon as the first frames arrive; waiting to buffer 3 s first made the
            // start of playback take seconds on a slow mirror. Mid-play underruns still pause.
            "cache-pause": "yes", "cache-pause-initial": "no", "cache-pause-wait": "3",
            "network-timeout": "15",
            "user-agent": "Mozilla/5.0", "referrer": "https://www.bilibili.com/",
        ]
        for (key, value) in options { mpv_set_option_string(core, key, value) }
        let result = mpv_initialize(core)
        guard result >= 0 else {
            mpv_terminate_destroy(core)
            throw MPVError(message: String(cString: mpv_error_string(result)))
        }
        updatePolling()
    }

    private func updatePolling() {
        // Keep loading responsive. A ready, paused background core continues
        // buffering/decoding independently of this UI status timer.
        let interval = isForeground || !loaded ? 0.25 : 1.0
        guard pollInterval != interval else { return }
        poll?.invalidate()
        pollInterval = interval
        poll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    /// Read-ahead grows with playing time, as in the official player: a short target at the
    /// start keeps deep read-ahead from competing with the first video and audio requests.
    static let readAheadStages: [Double] = [20, 40, 70]
    private enum BufferPolicy { case onDemand, live }
    private var bufferPolicy = BufferPolicy.onDemand
    private(set) var bufferStage = 0
    private var playingSince: Date?

    /// Moves to the read-ahead stage for `seconds` of playing time (5 s and 20 s steps).
    func updateBufferStage(playing seconds: TimeInterval) {
        guard bufferPolicy == .onDemand else { return }
        let stage = seconds >= 20 ? 2 : seconds >= 5 ? 1 : 0
        guard stage != bufferStage else { return }
        bufferStage = stage
        applyBufferPolicy()
    }

    private func applyBufferPolicy() {
        if bufferPolicy == .live {
            // Live streams retain a short target, including after rate changes and reconnects.
            set("cache-secs", "5")
            set("demuxer-readahead-secs", "5")
            set("cache-pause-wait", "1")
            set("demuxer-max-bytes", String(128 * 1024 * 1024))
            return
        }
        // mpv measures media seconds, so preserve a useful wall-clock margin at higher rates.
        let multiplier = max(1, min(3, speed.isFinite ? speed : 1))
        let seconds = Self.readAheadStages[bufferStage]
        set("cache-secs", String(seconds * multiplier))
        set("demuxer-readahead-secs", String(seconds * multiplier))
        set("cache-pause-wait", String(3 * multiplier))
        set("demuxer-max-bytes", String(Int(min(256, 128 * multiplier)) * 1024 * 1024))
    }

    deinit {
        durationProbe?.cancel()
        poll?.invalidate()
        mpv_terminate_destroy(handle)
    }
    func load(
        _ playback: Playback, position: Double, autoplay: Bool,
        videoURL: URL? = nil, audioURL: URL? = nil,
        diagnostics: PlaybackDiagnosticContext? = nil
    ) throws {
        try loadSource(
            videoURL ?? playback.videoStream?.urls.first ?? playback.url,
            audio: audioURL ?? playback.audioStream?.urls.first, position: position,
            autoplay: autoplay, bufferPolicy: .onDemand, diagnostics: diagnostics)
    }

    func loadLive(_ url: URL, autoplay: Bool) throws {
        set("referrer", "https://live.bilibili.com/")
        try loadSource(
            url, audio: nil, position: 0, autoplay: autoplay, bufferPolicy: .live, diagnostics: nil)
    }

    private func loadSource(
        _ source: URL, audio: URL?, position: Double, autoplay: Bool,
        bufferPolicy: BufferPolicy, diagnostics: PlaybackDiagnosticContext?
    ) throws {
        resetDurationProbe()
        trackSources = audio.map { [.video: source, .audio: $0] } ?? [:]
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
        failure = nil
        failureCode = nil
        prematureEnd = false
        entryID = nil
        waitingForStart = true
        diagnosticContext = diagnostics
        if let diagnostics { NSLog("mpv request: %@", diagnostics.summary) }
        reported = false
        wasCachePaused = false
        loaded = false
        lastUpdate = nil
        updatePolling()
        playingSince = nil
        bufferStage = 0
        self.bufferPolicy = bufferPolicy
        applyBufferPolicy()
        playbackActivity.setActive(false)
        set("pause", autoplay ? "no" : "yes")
        let options = "start=\(max(0, position)),speed=\(speed)"
        let media: String
        if let audio {
            let tracks = [source, audio].map { url in
                let text = url.absoluteString
                return "%\(text.utf8.count)%" + text
            }
            media = "edl://" + tracks.joined(separator: ";!new_stream;")
        } else {
            media = source.absoluteString
        }
        commandSequence += 1
        loadCommandID = commandSequence
        try command(["loadfile", media, "replace", "-1", options], id: loadCommandID)
    }
    func pause() {
        set("pause", "yes")
        playbackActivity.setActive(false)
    }
    func play() {
        if ended { seek(0) }
        set("pause", "no")
    }
    func subtitleFrame() async -> SubtitleFrame? {
        guard loaded else { return nil }
        return await captureVideoFrame?()
    }

    func stop() {
        resetDurationProbe()
        waitingForStart = true
        loadCommandID = 0
        try? command(["stop"])
        loaded = false
        playbackActivity.setActive(false)
    }
    func seek(_ value: Double) {
        guard value.isFinite else { return }
        try? command(["seek", String(max(0, value)), "absolute+exact"])
    }
    func set(_ name: String, _ value: String) { mpv_set_property_string(handle, name, value) }
    func number(_ name: String) -> Double {
        var result = 0.0
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &result)
        return result.isFinite ? result : 0
    }
    func text(_ name: String) -> String {
        guard let value = mpv_get_property_string(handle, name) else { return "" }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    func flag(_ name: String) -> Bool {
        var result: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &result)
        return result != 0
    }
    private func command(_ arguments: [String], id: UInt64 = 0) throws {
        let strings = arguments.map { strdup($0) }
        defer { for string in strings { free(string) } }
        var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
        let result = mpv_command_async(handle, id, &pointers)
        if result < 0 {
            throw MPVError(message: String(cString: mpv_error_string(result)), code: result)
        }
    }
    private func update() {
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_START_FILE:
                entryID =
                    event.pointee.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee
                    .playlist_entry_id
                waitingForStart = false
            case MPV_EVENT_FILE_LOADED: if !waitingForStart { loaded = true }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self),
                    !waitingForStart, data.pointee.playlist_entry_id == entryID,
                    data.pointee.error < 0
                {
                    failure = String(cString: mpv_error_string(data.pointee.error))
                    failureCode = data.pointee.error
                    NSLog(
                        "mpv failure: session=%@ stage=media code=%d",
                        diagnosticContext?.session.uuidString ?? "none", data.pointee.error)
                }
            case MPV_EVENT_COMMAND_REPLY:
                if event.pointee.reply_userdata == loadCommandID, loadCommandID != 0,
                    event.pointee.error < 0
                {
                    failure = String(cString: mpv_error_string(event.pointee.error))
                    failureCode = event.pointee.error
                }
            default: break
            }
        }
        detectPrematureEnd()
        if loaded && time > 0 && !reported {
            reported = true
            NSLog(
                "mpv playback: %@; decoder=%@; %.0fx%.0f; audio=%.0fch; muted=%@",
                text("mpv-version"), text("hwdec-current"), number("video-params/w"),
                number("video-params/h"), number("audio-params/channel-count"), muted ? "yes" : "no"
            )
        }
        let cachePaused = flag("paused-for-cache")
        if cachePaused != wasCachePaused {
            NSLog(
                "mpv buffer: %@; rate=%.2f; ahead=%.2fs; download=%.0fKiB/s; decoder-drops=%.0f; output-drops=%.0f",
                cachePaused ? "waiting" : "resumed", speed, number("demuxer-cache-duration"),
                number("cache-speed") / 1024, number("decoder-frame-drop-count"),
                number("frame-drop-count"))
            wasCachePaused = cachePaused
        }
        playbackActivity.setActive(playing && failure == nil)
        if playing, failure == nil {
            if playingSince == nil { playingSince = Date() }
            updateBufferStage(playing: Date().timeIntervalSince(playingSince!))
        }
        updatePolling()
        let snapshot = Snapshot(
            time: time, duration: duration, playing: playing,
            buffering: cachePaused || (!loaded && failure == nil), loaded: loaded,
            ended: ended, failure: failure)
        // Foreground callbacks also drive periodic persistence; failures drive
        // recovery transitions even when mpv's properties have not changed.
        guard isForeground || snapshot.failure != nil || snapshot != lastUpdate else { return }
        lastUpdate = snapshot
        onUpdate?(snapshot.time, snapshot.duration, snapshot.playing, snapshot.buffering)
    }

    private func detectPrematureEnd() {
        guard loaded, failure == nil, bufferPolicy == .onDemand, !flag("seeking") else { return }
        let length = duration
        guard length > 0 else { return }
        let reachedEnd = flag("eof-reached")
        guard reachedEnd || flag("demuxer-cache-idle") else { return }
        let cache = cacheSnapshot
        guard reachedEnd || cache?.eof == true else { return }
        if trackSources.isEmpty {
            let selected = (0..<Int(number("track-list/count"))).compactMap { index -> String? in
                let type = text("track-list/\(index)/type")
                return flag("track-list/\(index)/selected") && ["video", "audio"].contains(type)
                    ? type : nil
            }
            if selected.count == 1 {
                if reachedEnd {
                    reportPrematureEnd(at: time, duration: length)
                } else if let end = cache?.videoEnd ?? cache?.audioEnd ?? cache?.end {
                    reportPrematureEnd(at: end, duration: length)
                }
            } else if reachedEnd, let cache, cache.eof {
                // mpv can stop at the shorter video track. A longer complete
                // audio track is valid; require every selected track to be short.
                let ends = selected.compactMap { $0 == "video" ? cache.videoEnd : cache.audioEnd }
                if ends.count == selected.count, let end = ends.max() {
                    reportPrematureEnd(at: end, duration: length)
                }
            }
            return
        }
        guard let cache else { return }
        let ends: [SourceTrack: Double?] = [.video: cache.videoEnd, .audio: cache.audioEnd]
        let candidates = ends.compactMapValues { $0 }.filter {
            Self.endedPrematurely(at: $0.value, duration: length)
        }
        for (track, end) in candidates {
            if let declared = trackDurations[track],
                Self.endedPrematurely(at: end, duration: declared)
            {
                reportPrematureEnd(at: end, duration: declared)
                return
            }
        }
        guard durationProbe == nil else { return }
        let sources = trackSources.filter {
            candidates[$0.key] != nil && !probedTracks.contains($0.key)
        }
        guard !sources.isEmpty else { return }
        probedTracks.formUnion(sources.keys)
        let request = sourceGeneration
        durationProbe = Task { [weak self] in
            let durations = await withTaskGroup(of: (SourceTrack, Double?).self) { group in
                for (track, url) in sources {
                    group.addTask { (track, await MediaSourceDuration.load(url)) }
                }
                var result: [SourceTrack: Double] = [:]
                for await (track, length) in group {
                    if let length { result[track] = length }
                }
                return result
            }
            guard let self, !Task.isCancelled, self.sourceGeneration == request else { return }
            self.trackDurations.merge(durations) { _, new in new }
            self.durationProbe = nil
            self.update()
        }
    }

    private func resetDurationProbe() {
        sourceGeneration = UUID()
        durationProbe?.cancel()
        durationProbe = nil
        probedTracks = []
        trackSources = [:]
        trackDurations = [:]
    }

    private func reportPrematureEnd(at cutoff: Double, duration length: Double) {
        guard Self.endedPrematurely(at: cutoff, duration: length) else { return }
        prematureEnd = true
        failureCode = -13
        failure = "视频流提前结束"
        pause()
        Self.logger.notice(
            "Premature EOF: session=\(self.diagnosticContext?.session.uuidString ?? "none", privacy: .public) position=\(self.time, privacy: .public) cutoff=\(cutoff, privacy: .public) duration=\(length, privacy: .public)"
        )
    }

    nonisolated static func endedPrematurely(at position: Double, duration: Double) -> Bool {
        position.isFinite && duration.isFinite && position >= 0 && duration > 0
            && duration - position > max(3, min(10, duration * 0.01))
    }

    var diagnosticSummary: String {
        let context = diagnosticContext?.summary ?? "尚未加载播放源"
        return
            "\(context)\nmpv=\(text("mpv-version")) decoder=\(text("hwdec-current")) buffer-seconds=\(number("demuxer-cache-duration")) download-bps=\(number("cache-speed")) speed=\(speed) decoder-drops=\(number("decoder-frame-drop-count")) output-drops=\(number("frame-drop-count")) error-code=\(failureCode ?? 0)"
    }
}

struct MPVError: LocalizedError {
    let message: String
    var code: Int32? = nil
    var errorDescription: String? { message }
}

struct MPVSurface: NSViewRepresentable {
    let player: MPVPlayer
    func makeNSView(context: Context) -> Surface { Surface(player: player)! }
    func updateNSView(_ view: Surface, context: Context) {}
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.releaseRenderer() }

    /// Hosts the video layer; frames are drawn on the layer's render queue, not here.
    final class Surface: NSView {
        let player: MPVPlayer
        let video: MPVVideoLayer
        init?(player: MPVPlayer) {
            guard let video = MPVVideoLayer(handle: player.handle) else { return nil }
            self.player = player
            self.video = video
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
            player.captureVideoFrame = { [weak player, video] in
                guard let player else { return nil }
                return await video.subtitleFrame(
                    sourceWidth: player.number("video-params/w"),
                    sourceHeight: player.number("video-params/h"))
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func makeBackingLayer() -> CALayer { video }
        override var isOpaque: Bool { true }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            video.contentsScale = window?.backingScaleFactor ?? 2
            video.setNeedsDisplay()
        }
        func releaseRenderer() {
            player.captureVideoFrame = nil
            video.releaseRenderer(keepingAlive: player)
        }
        // The layer can outlive this view; its render context must not outlive the player.
        deinit { video.releaseRenderer(keepingAlive: player) }
    }
}
