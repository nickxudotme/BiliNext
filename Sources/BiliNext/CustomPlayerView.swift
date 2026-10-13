import AVFoundation
import AppKit
import BiliNextCore
import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    final class Surface: NSView {
        let video = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(video)
            video.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            video.frame = bounds
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.video.player = player
        return view
    }
    func updateNSView(_ view: Surface, context: Context) { view.video.player = player }
}

struct CustomPlayerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var clock: PlaybackClock
    init(
        model: AppModel, danmaku: DanmakuModel, isActive: Bool = true, miniPlayer: Bool = false,
        windowPinned: Bool = false, onControlsVisibility: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isActive = isActive
        self.miniPlayer = miniPlayer
        self.windowPinned = windowPinned
        self.onControlsVisibility = onControlsVisibility
        self.model = model
        self.danmaku = danmaku
        self.clock = model.playbackClock
        self.smartSubtitles = model.smartSubtitles
    }

    var isActive: Bool
    var miniPlayer: Bool
    /// 置顶 lives on the workspace model, so the shell passes it down with 小窗.
    var windowPinned: Bool
    var onControlsVisibility: (Bool) -> Void
    private var controlsVisible: Bool {
        controls || !model.playing || scrubbing || settings || qualitySettings || rateSettings
    }
    @ObservedObject var danmaku: DanmakuModel
    @State private var controls = true
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var hideTask: Task<Void, Never>?
    @State private var settings = false
    @State private var qualitySettings = false
    @State private var rateSettings = false
    @State private var availableWidth: CGFloat = 600
    @State private var availableHeight: CGFloat = 400
    @State private var hoveringBar = false
    @State private var lastPointer: CGPoint?
    @State private var volumeHover = false
    @State private var volumeBeforeMute = 1.0
    @State private var boostedFrom: Double?
    @State private var arrowDown: Date?
    @State private var theaterBeforeFullscreen: Bool?
    @AppStorage("player.highEnergy") private var highEnergyEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @AppStorage("danmaku.opacity") private var opacity = 0.85
    @AppStorage("danmaku.font") private var fontSize = 20.0
    @AppStorage("danmaku.area") private var area = 0.5
    @AppStorage("danmaku.speed") private var dmSpeed = 1.0
    @AppStorage("danmaku.blocked") private var blocked = ""
    @AppStorage("danmaku.rolling") private var rolling = true
    @AppStorage("danmaku.fixed") private var fixed = true
    @ObservedObject private var smartSubtitles: SmartSubtitleModel

    var body: some View {
        ZStack {
            if let mpv = model.mpv {
                MPVSurface(player: mpv)
            } else {
                VideoSurface(player: model.player)
            }
            DanmakuCanvas(
                player: model.player, mpv: model.mpv, model: danmaku, time: model.time,
                playing: model.playing,
                opacity: opacity, fontSize: fontSize, area: area, speed: dmSpeed, blocked: blocked,
                rolling: rolling, fixed: fixed
            )
            .allowsHitTesting(false)
            if smartSubtitles.visible {
                VStack {
                    Spacer()
                    SubtitleOverlay(
                        primary: model.cues, secondary: model.secondaryCues, time: model.time
                    )
                    .padding(.horizontal, 20)
                }.padding(.bottom, controlsVisible ? 104 : 20).allowsHitTesting(false)
                    .animation(Motion.standard(reduceMotion), value: controlsVisible)
            }
            if smartSubtitles.needsDecision {
                VStack {
                    HStack {
                        Text("画面字幕语言不同，保留软字幕？")
                        Button("保留") { smartSubtitles.resolveLanguage(keep: true) }
                        Button("隐藏") { smartSubtitles.resolveLanguage(keep: false) }
                    }.font(GlassTheme.labelFont).controlSize(.regular).padding(12).background(
                        .regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                }.padding(16)
            }
            if model.videoLoading || model.buffering {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if boostedFrom != nil {
                Label("2× 倍速播放中", systemImage: "forward.fill")
                    .font(GlassTheme.labelFont.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let error = model.playerError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text(error).font(GlassTheme.bodyFont).multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("重新加载") { model.refresh() }.buttonStyle(.glass).controlSize(.large)
                }
                .padding(24).foregroundStyle(.white).frame(
                    maxWidth: .infinity, maxHeight: .infinity
                ).background(.black.opacity(0.8))
                .environment(\.colorScheme, .dark)
            }
            if controlsVisible {
                VStack {
                    Spacer()
                    controlsBar
                }.transition(.opacity)
            } else if model.duration > 0 {
                // A hairline of progress stays visible while the controls are hidden.
                GeometryReader { proxy in
                    Rectangle().fill(GlassTheme.accent)
                        .frame(
                            width: proxy.size.width * min(1, max(0, model.time / model.duration)),
                            height: 2)
                }
                .frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(.black)
        .contentShape(Rectangle()).focusable(isActive).focused($focused).focusEffectDisabled()
        .onTapGesture {
            focused = true
            model.togglePlayback()
            revealControls()
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard point != lastPointer else { return }
                lastPointer = point
                // Resting over the picture hides sooner than resting near the edges.
                let middle = point.y > availableHeight / 3 && point.y < availableHeight * 2 / 3
                revealControls(hideAfter: middle ? 1.2 : 3)
            case .ended:
                lastPointer = nil
                revealControls(hideAfter: 0.3, reveal: false)
            }
        }
        .onKeyPress(.space) {
            model.togglePlayback()
            revealControls()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.seek(max(0, model.time - 5))
            revealControls()
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat, .up]) { press in
            // Tap → skips 5 s; holding it plays at 2× until released, as in the official client.
            switch press.phase {
            case .down:
                arrowDown = Date()
            case .repeat:
                if boostedFrom == nil, let start = arrowDown, Date().timeIntervalSince(start) > 0.35
                {
                    withAnimation(Motion.standard(reduceMotion)) {
                        boostedFrom = model.playbackRate
                    }
                    model.setRate(2)
                }
            default:
                if let previous = boostedFrom {
                    model.setRate(previous)
                    withAnimation(Motion.standard(reduceMotion)) { boostedFrom = nil }
                } else {
                    model.seek(min(model.duration, model.time + 5))
                    revealControls()
                }
                arrowDown = nil
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            setVolume(model.playerVolume + 0.1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            setVolume(model.playerVolume - 0.1)
            return .handled
        }
        .onKeyPress("q") {
            model.toggleLike()
            return .handled
        }
        .onKeyPress("w") {
            model.requestCoin()
            return .handled
        }
        .onKeyPress("e") {
            model.requestFavorite()
            return .handled
        }
        .onKeyPress("m") {
            toggleMute()
            return .handled
        }
        .onKeyPress("[") {
            if let cid = page(offset: -1) { model.selectPage(cid) }
            return .handled
        }
        .onKeyPress("]") {
            if let cid = page(offset: 1) { model.selectPage(cid) }
            return .handled
        }
        .onKeyPress("f") {
            toggleFullscreen()
            return .handled
        }
        .onKeyPress("d") {
            danmaku.enabled.toggle()
            return .handled
        }
        .onAppear {
            scrubTime = model.time
            onControlsVisibility(true)
        }
        .onChange(of: controlsVisible) { _, value in onControlsVisibility(value) }
        .onChange(of: model.playing) { _, _ in revealControls() }
        .onChange(of: model.time) { _, value in if !scrubbing { scrubTime = value } }
        .onChange(of: scrubTime) { _, value in
            if !scrubbing && model.duration > 0 && abs(value - model.time) > 1 { model.seek(value) }
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            availableWidth = $0.width
            availableHeight = $0.height
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
            if let previous = theaterBeforeFullscreen { model.theater = previous }
            theaterBeforeFullscreen = nil
        }
        .onChange(of: isActive) { _, active in
            focused = active
            if !active { hideTask?.cancel() }
        }
        .onDisappear { hideTask?.cancel() }
    }
    private var controlsBar: some View {
        let compact = availableWidth <= 540 || miniPlayer
        return VStack(spacing: 2) {
            HStack(spacing: 10) {
                PlaybackScrubber(
                    time: model.time, duration: model.duration,
                    buffered: model.mpv.map { $0.number("demuxer-cache-time") } ?? 0,
                    activity: highEnergyEnabled ? model.highEnergy?.samples ?? [] : [],
                    showsActivity: hoveringBar, scrubbing: $scrubbing, scrubTime: $scrubTime,
                    seek: { model.seek($0) }, interact: { revealControls() }
                )
                .disabled(model.duration <= 0)
                if compact {
                    timeLabel.fixedSize(horizontal: true, vertical: false)
                }
            }
            HStack(spacing: compact ? 2 : 4) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20)).contentTransition(.symbolEffect(.replace))
                        .iconControlFrame(size: 36)
                }.help(model.playing ? "暂停 · 空格" : "播放 · 空格")
                    .accessibilityLabel(model.playing ? "暂停" : "播放")
                if let next = page(offset: 1) {
                    Button {
                        model.selectPage(next)
                    } label: {
                        Image(systemName: "forward.end.fill").iconControlFrame()
                    }.help("下一 P · ]").accessibilityLabel("下一 P")
                }
                volumeControl
                if !compact {
                    timeLabel.padding(.leading, 4)
                }
                Spacer(minLength: 2)
                if !model.qualities.isEmpty && !compact {
                    textButton(model.quality, active: qualitySettings) { qualitySettings.toggle() }
                        .help("清晰度")
                        .popover(isPresented: $qualitySettings, arrowEdge: .top) {
                            optionList(
                                "清晰度", options: model.qualities.map { ($0.value, $0.label) },
                                selected: model.qualityID
                            ) {
                                model.selectQuality($0)
                                qualitySettings = false
                            }
                        }
                }
                if !miniPlayer {
                    textButton(
                        model.playbackRate == 1
                            ? "倍速" : String(format: "%g×", model.playbackRate),
                        active: rateSettings
                    ) { rateSettings.toggle() }
                    .help("播放速度 · 长按 → 2×")
                    .popover(isPresented: $rateSettings, arrowEdge: .top) {
                        optionList(
                            "播放速度",
                            options: [0.5, 0.75, 1, 1.25, 1.5, 2, 3].map {
                                (Int($0 * 100), String(format: "%g×", $0))
                            },
                            selected: Int(model.playbackRate * 100)
                        ) {
                            model.setRate(Double($0) / 100)
                            rateSettings = false
                        }
                    }
                }
                Button {
                    danmaku.enabled.toggle()
                } label: {
                    Image(systemName: danmaku.enabled ? "text.bubble.fill" : "text.bubble")
                        .foregroundStyle(danmaku.enabled ? GlassTheme.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .iconControlFrame()
                }.help(danmaku.enabled ? "关闭弹幕 · D" : "开启弹幕 · D").accessibilityLabel("弹幕开关")
                if !miniPlayer && (!compact || availableWidth > 480) {
                    Button {
                        smartSubtitles.setVisible(!smartSubtitles.visible)
                    } label: {
                        Image(
                            systemName: smartSubtitles.visible
                                ? "captions.bubble.fill" : "captions.bubble"
                        )
                        .foregroundStyle(smartSubtitles.visible ? GlassTheme.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .iconControlFrame()
                    }.help("画面字幕").accessibilityLabel(
                        smartSubtitles.visible ? "隐藏画面软字幕" : "显示画面软字幕")
                }
                if !miniPlayer {
                    Button {
                        settings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3").iconControlFrame()
                    }.help("字幕与弹幕设置").accessibilityLabel("字幕与弹幕设置")
                        .popover(isPresented: $settings, arrowEdge: .top) { settingsPanel }
                }
                Button {
                    model.toggleWindowPin()
                } label: {
                    Image(systemName: windowPinned ? "pin.fill" : "pin")
                        .foregroundStyle(windowPinned ? GlassTheme.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .iconControlFrame()
                }.help(windowPinned ? "取消置顶 · ⌥⌘P" : "窗口置顶 · ⌥⌘P")
                    .accessibilityLabel(windowPinned ? "取消置顶" : "窗口置顶")
                Button {
                    model.toggleMiniPlayer()
                } label: {
                    Image(
                        systemName: miniPlayer
                            ? "arrow.up.backward.and.arrow.down.forward" : "pip"
                    )
                    .iconControlFrame()
                }.help(miniPlayer ? "退出小窗 · Esc" : "小窗播放 · ⌥⌘M")
                    .accessibilityLabel(miniPlayer ? "退出小窗" : "小窗播放")
                if !miniPlayer {
                    Button {
                        model.theater.toggle()
                    } label: {
                        Image(
                            systemName: model.theater
                                ? "sidebar.trailing" : "rectangle.expand.vertical"
                        )
                        .iconControlFrame()
                    }.help(model.theater ? "显示视频详情" : "剧场模式")
                        .accessibilityLabel(model.theater ? "显示视频详情" : "剧场模式")
                    Button {
                        toggleFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").iconControlFrame()
                    }.help("全屏 · F").accessibilityLabel("全屏")
                }
            }
            .font(.system(size: 17, weight: .medium)).buttonStyle(InteractionButtonStyle())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.top, 44).padding(.bottom, 10)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .black.opacity(0.82), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        // Controls over video always use light glyphs on dark feedback, in both appearances.
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            hoveringBar = inside
            if inside { revealControls() }
        }
        .onTapGesture {
            // Keep control clicks from toggling the video surface.
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 0) {
            Button {
                toggleMute()
            } label: {
                Image(systemName: volumeSymbol).contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, alignment: .leading).iconControlFrame()
            }.help(model.playerVolume == 0 ? "取消静音 · M" : "静音 · M")
                .accessibilityLabel(model.playerVolume == 0 ? "取消静音" : "静音")
            if volumeHover {
                Slider(
                    value: Binding(get: { model.playerVolume }, set: { setVolume($0) }), in: 0...1
                )
                .controlSize(.small).tint(.white).frame(width: 84)
                .accessibilityLabel("音量")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onHover { inside in
            withAnimation(Motion.standard(reduceMotion)) { volumeHover = inside }
        }
    }

    private var volumeSymbol: String {
        switch model.playerVolume {
        case ...0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private func textButton(
        _ title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title).font(GlassTheme.labelFont.weight(.semibold)).lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(active ? GlassTheme.accent : .white)
                .padding(.horizontal, 8).frame(minWidth: 44, minHeight: GlassTheme.iconControlSize)
                .contentShape(Rectangle())
        }
    }

    private func optionList(
        _ title: String, options: [(Int, String)], selected: Int,
        choose: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(GlassTheme.metadataFont.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(options, id: \.0) { option in
                PlayerOptionRow(title: option.1, selected: option.0 == selected) {
                    choose(option.0)
                }
            }
        }
        .padding(8).frame(width: 180)
    }

    private var timeLabel: some View {
        Text("\(timestamp(scrubbing ? scrubTime : model.time)) / \(timestamp(model.duration))")
            .font(GlassTheme.metadataFont.monospacedDigit())
            .foregroundStyle(.white).lineLimit(1)
    }
    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("字幕与弹幕").font(GlassTheme.readingFont.weight(.semibold))
                Text("显示").font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    .padding(.top, 8)
                Toggle("显示弹幕", isOn: $danmaku.enabled)
                SubtitleTrackControls(model: model)
                SmartSubtitleSettings(
                    model: smartSubtitles,
                    automaticDetectionSuspended: !model.secondaryTrackID.isEmpty)
                if availableWidth <= 540 {
                    Picker(
                        "清晰度",
                        selection: Binding(
                            get: { model.qualityID }, set: { model.selectQuality($0) })
                    ) { ForEach(model.qualities) { Text($0.label).tag($0.value) } }
                }
                Divider().padding(.vertical, 4)
                Text("弹幕类型").font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                Toggle("滚动弹幕", isOn: $rolling)
                Toggle("顶部和底部弹幕", isOn: $fixed)
                Divider().padding(.vertical, 4)
                Text("进度条").font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                Toggle("高能进度条", isOn: $highEnergyEnabled)
                Divider().padding(.vertical, 4)
                Text("外观").font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                LabeledContent("不透明度", value: "\(Int(opacity * 100))%")
                Slider(value: $opacity, in: 0.2...1)
                LabeledContent("字号", value: "\(Int(fontSize)) pt")
                Slider(value: $fontSize, in: 14...32, step: 1)
                LabeledContent("显示区域", value: "\(Int(area * 100))%")
                Slider(value: $area, in: 0.25...1, step: 0.25)
                LabeledContent("弹幕速度", value: String(format: "%g×", dmSpeed))
                Slider(value: $dmSpeed, in: 0.5...2, step: 0.25)
                Divider().padding(.vertical, 4)
                Text("屏蔽").font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                TextField("屏蔽关键词，用逗号分隔", text: $blocked).textFieldStyle(.roundedBorder)
                if let error = danmaku.error {
                    Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    Button("重试") {
                        danmaku.retry()
                        model.updateDanmaku()
                    }
                }
                Text(danmaku.loading ? "正在加载弹幕…" : "已加载 \(danmaku.comments.count) 条弹幕").font(
                    GlassTheme.metadataFont
                ).foregroundStyle(.secondary)
            }.font(GlassTheme.labelFont).controlSize(.regular).padding(16)
        }.frame(width: 320, height: 480)
    }
    /// Shows the controls (unless only rescheduling) and hides them again after a pause,
    /// while playback runs and nothing in the bar is being used.
    private func revealControls(hideAfter delay: Double = 3, reveal: Bool = true) {
        if reveal && !controls {
            withAnimation(Motion.standard(reduceMotion)) { controls = true }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, model.playing, !scrubbing, !settings, !qualitySettings,
                !rateSettings, !(hoveringBar && reveal)
            else { return }
            withAnimation(Motion.standard(reduceMotion)) { controls = false }
        }
    }

    private func toggleFullscreen() {
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == false {
            theaterBeforeFullscreen = model.theater
            model.theater = true
        }
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func setVolume(_ value: Double) {
        model.playerVolume = min(1, max(0, value))
        model.objectWillChange.send()
        revealControls()
    }

    private func toggleMute() {
        if model.playerVolume > 0 {
            volumeBeforeMute = model.playerVolume
            setVolume(0)
        } else {
            setVolume(max(0.1, volumeBeforeMute))
        }
    }

    /// The neighbouring part of a multi-part video, if there is one.
    private func page(offset: Int) -> Int64? {
        guard let pages = model.detail?.pages,
            let index = pages.firstIndex(where: { $0.cid == model.pageID }),
            pages.indices.contains(index + offset)
        else { return nil }
        return pages[index + offset].cid
    }
}
