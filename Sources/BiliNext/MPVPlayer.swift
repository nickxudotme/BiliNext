import AppKit
import BiliNextCore
import CMPV
import OpenGL.GL3
import SwiftUI

/// One libmpv instance per retained playback tab; preview remains a separate muted AVPlayer.
@MainActor
final class MPVPlayer {
    let handle: OpaquePointer
    private var poll: Timer?
    private let playbackActivity = PlaybackActivity()
    private(set) var loaded = false
    private(set) var failure: String?
    private(set) var failureCode: Int32?
    private(set) var diagnosticContext: PlaybackDiagnosticContext?
    private var commandSequence: UInt64 = 0
    private var loadCommandID: UInt64 = 0
    private var entryID: Int64?
    private var waitingForStart = false
    private var reported = false
    private var wasCachePaused = false
    var captureVideoFrame: (() -> SubtitleFrame?)?
    var onUpdate: ((Double, Double, Bool, Bool) -> Void)?
    var time: Double { number("time-pos") }
    var duration: Double { number("duration") }
    var playing: Bool { loaded && failure == nil && !flag("pause") && !flag("eof-reached") }
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
            "cache": "yes", "cache-secs": "60", "demuxer-max-bytes": "134217728",
            "demuxer-readahead-secs": "60", "demuxer-max-back-bytes": "16777216",
            "cache-pause": "yes", "cache-pause-initial": "yes", "cache-pause-wait": "3",
            "network-timeout": "15",
            "user-agent": "Mozilla/5.0", "referrer": "https://www.bilibili.com/",
        ]
        for (key, value) in options { mpv_set_option_string(core, key, value) }
        let result = mpv_initialize(core)
        guard result >= 0 else {
            mpv_terminate_destroy(core)
            throw MPVError(message: String(cString: mpv_error_string(result)))
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    private func applyBufferPolicy() {
        // mpv measures media seconds, so preserve a useful wall-clock margin at higher rates.
        let multiplier = max(1, min(3, speed.isFinite ? speed : 1))
        set("cache-secs", String(60 * multiplier))
        set("demuxer-readahead-secs", String(60 * multiplier))
        set("cache-pause-wait", String(3 * multiplier))
        set("demuxer-max-bytes", String(Int(min(256, 128 * multiplier)) * 1024 * 1024))
    }

    deinit {
        poll?.invalidate()
        mpv_terminate_destroy(handle)
    }
    func load(
        _ playback: Playback, position: Double, autoplay: Bool,
        videoURL: URL? = nil, audioURL: URL? = nil,
        diagnostics: PlaybackDiagnosticContext? = nil
    ) throws {
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
        failure = nil
        failureCode = nil
        entryID = nil
        waitingForStart = true
        diagnosticContext = diagnostics
        if let diagnostics { NSLog("mpv request: %@", diagnostics.summary) }
        reported = false
        wasCachePaused = false
        loaded = false
        playbackActivity.setActive(false)
        set("pause", autoplay ? "no" : "yes")
        // mpv accepts an independently fetched audio stream without a local HLS bridge.
        let source = videoURL ?? playback.videoStream?.urls.first ?? playback.url
        let audio = audioURL ?? playback.audioStream?.urls.first
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
    func play() { set("pause", "no") }
    func subtitleFrame() async -> SubtitleFrame? {
        guard loaded else { return nil }
        return captureVideoFrame?()
    }

    func stop() {
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
        onUpdate?(time, duration, playing, cachePaused || (!loaded && failure == nil))
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

    final class Surface: NSOpenGLView {
        let player: MPVPlayer
        var renderer: OpaquePointer?
        init?(player: MPVPlayer) {
            self.player = player
            let attributes: [NSOpenGLPixelFormatAttribute] = [
                UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
                UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFADoubleBuffer), 0,
            ]
            super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes)!)
            wantsBestResolutionOpenGLSurface = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func prepareOpenGL() {
            super.prepareOpenGL()
            guard renderer == nil else { return }
            openGLContext?.makeCurrentContext()
            var initialization = mpv_opengl_init_params(
                get_proc_address: { _, name in
                    guard let name else { return nil }
                    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
                }, get_proc_address_ctx: nil)
            "opengl".withCString { api in
                withUnsafeMutablePointer(to: &initialization) { gl in
                    var parameters = [
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_API_TYPE,
                            data: UnsafeMutableRawPointer(mutating: api)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: gl),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    let result = mpv_render_context_create(&renderer, player.handle, &parameters)
                    if result < 0 { NSLog("mpv renderer: %s", mpv_error_string(result)) }
                }
            }
            if let renderer {
                player.captureVideoFrame = { [weak self] in self?.captureSubtitleFrame() }
                mpv_render_context_set_update_callback(
                    renderer,
                    { context in
                        guard let context else { return }
                        let view = Unmanaged<Surface>.fromOpaque(context).takeUnretainedValue()
                        DispatchQueue.main.async { [weak view] in view?.needsDisplay = true }
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            openGLContext?.makeCurrentContext()
            guard let renderer else { return }
            let size = convertToBacking(bounds).size
            var fbo = mpv_opengl_fbo(
                fbo: 0, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
            var flip: Int32 = 1
            var block: Int32 = 0
            withUnsafeMutablePointer(to: &fbo) { buffer in
                withUnsafeMutablePointer(to: &flip) { orientation in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: buffer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: orientation),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    withUnsafeMutablePointer(to: &block) { wait in
                        parameters.insert(
                            mpv_render_param(
                                type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: wait), at: 2)
                        mpv_render_context_render(renderer, &parameters)
                    }
                }
            }
            openGLContext?.flushBuffer()
        }
        override func reshape() {
            super.reshape()
            needsDisplay = true
        }
        func releaseRenderer() {
            guard let renderer else { return }
            player.captureVideoFrame = nil
            openGLContext?.makeCurrentContext()
            mpv_render_context_set_update_callback(renderer, nil, nil)
            mpv_render_context_free(renderer)
            self.renderer = nil
        }
        deinit { releaseRenderer() }
    }
}
