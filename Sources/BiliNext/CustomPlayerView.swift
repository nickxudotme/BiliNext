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
        model: AppModel, danmaku: DanmakuModel, isActive: Bool = true,
        onControlsVisibility: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isActive = isActive
        self.onControlsVisibility = onControlsVisibility
        self.model = model
        self.danmaku = danmaku
        self.clock = model.playbackClock
    }

    var isActive: Bool
    var onControlsVisibility: (Bool) -> Void
    private var controlsVisible: Bool {
        controls || !model.playing || scrubbing || settings || volumeSettings || qualitySettings
            || rateSettings
    }
    @ObservedObject var danmaku: DanmakuModel
    @State private var controls = true
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var hideTask: Task<Void, Never>?
    @State private var settings = false
    @State private var volumeSettings = false
    @State private var qualitySettings = false
    @State private var rateSettings = false
    @State private var availableWidth: CGFloat = 600
    @FocusState private var focused: Bool
    @AppStorage("danmaku.opacity") private var opacity = 0.85
    @AppStorage("danmaku.font") private var fontSize = 20.0
    @AppStorage("danmaku.area") private var area = 0.5
    @AppStorage("danmaku.speed") private var dmSpeed = 1.0
    @AppStorage("danmaku.blocked") private var blocked = ""
    @AppStorage("danmaku.rolling") private var rolling = true
    @AppStorage("danmaku.fixed") private var fixed = true
    @AppStorage("player.subtitles") private var showSubtitles = true

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
            if showSubtitles {
                VStack {
                    Spacer()
                    let lines = model.cues.filter { $0.contains(model.time) }
                    if !lines.isEmpty {
                        Text(lines.map(\.text).joined(separator: "\n")).font(
                            .system(size: 18, weight: .medium)
                        ).multilineTextAlignment(.center)
                            .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 20)
                    }
                }.padding(.bottom, controls || !model.playing ? 76 : 20).allowsHitTesting(false)
            }
            if model.videoLoading || model.buffering {
                ProgressView().tint(.white).allowsHitTesting(false)
            }
            if let error = model.playerError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).multilineTextAlignment(.center)
                    Button("重新加载") { model.refresh() }
                }
                .padding(24).foregroundStyle(.white).frame(
                    maxWidth: .infinity, maxHeight: .infinity
                ).background(.black.opacity(0.8))
            }
            if controlsVisible {
                VStack {
                    Spacer()
                    controlsBar
                }.transition(.opacity)
            }
        }
        .background(.black)
        .contentShape(Rectangle()).focusable(isActive).focused($focused).focusEffectDisabled()
        .onTapGesture {
            focused = true
            model.togglePlayback()
            revealControls()
        }
        .onContinuousHover { phase in if case .active = phase { revealControls() } }
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
        .onKeyPress(.rightArrow) {
            model.seek(min(model.duration, model.time + 5))
            revealControls()
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
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .onChange(of: isActive) { _, active in
            focused = active
            if !active { hideTask?.cancel() }
        }
        .onDisappear { hideTask?.cancel() }
    }
    private var controlsBar: some View {
        VStack(spacing: 8) {
            Slider(
                value: $scrubTime, in: 0...max(1, model.duration),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { model.seek(scrubTime) }
                    revealControls()
                }
            ).tint(.white).accessibilityLabel("播放进度").disabled(model.duration <= 0)
            HStack(spacing: availableWidth > 540 ? 14 : 8) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 20)
                }.accessibilityLabel(model.playing ? "暂停" : "播放")
                Text(
                    "\(timestamp(scrubbing ? scrubTime : model.time)) / \(timestamp(model.duration))"
                ).font(.system(size: 11).monospacedDigit())
                Spacer(minLength: 2)
                if !model.qualities.isEmpty && availableWidth > 540 {
                    Button {
                        qualitySettings.toggle()
                    } label: {
                        Text(model.quality).font(.system(size: 10))
                    }.help("清晰度")
                        .popover(isPresented: $qualitySettings) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("清晰度").font(.headline)
                                ForEach(model.qualities) { option in
                                    Button(option.label) {
                                        model.selectQuality(option.value)
                                        qualitySettings = false
                                    }.buttonStyle(.bordered)
                                }
                            }.padding(16)
                        }
                }
                Button {
                    danmaku.enabled.toggle()
                } label: {
                    Image(systemName: danmaku.enabled ? "text.bubble.fill" : "text.bubble")
                }.help("弹幕开关 · D").accessibilityLabel("弹幕开关")
                Button {
                    settings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }.help("弹幕设置").accessibilityLabel("弹幕设置")
                    .popover(isPresented: $settings) { settingsPanel }
                Button {
                    rateSettings.toggle()
                } label: {
                    Text(String(format: "%g×", model.playbackRate))
                }.help("播放速度")
                    .popover(isPresented: $rateSettings) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("播放速度").font(.headline)
                            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { value in
                                Button(String(format: "%g×", value)) {
                                    model.setRate(value)
                                    rateSettings = false
                                }.buttonStyle(.bordered)
                            }
                        }.padding(16)
                    }
                if availableWidth > 480 {
                    Button {
                        showSubtitles.toggle()
                    } label: {
                        Image(
                            systemName: showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    }.help("画面字幕")
                }
                Button {
                    volumeSettings.toggle()
                } label: {
                    Image(systemName: model.playerVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                }.help("音量")
                    .popover(isPresented: $volumeSettings) {
                        Slider(
                            value: Binding(
                                get: { model.playerVolume },
                                set: {
                                    model.playerVolume = $0
                                    model.objectWillChange.send()
                                }), in: 0...1
                        ).frame(width: 140).padding(20).accessibilityLabel("音量")
                    }

                Button {
                    model.theater.toggle()
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }.help("剧场模式").accessibilityLabel("剧场模式")
                Button {
                    toggleFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }.help("全屏 · F").accessibilityLabel("全屏")
            }.font(.system(size: 13)).buttonStyle(InteractionButtonStyle()).foregroundStyle(.white)
        }.padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 14)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            )
            .onTapGesture {
                // Keep control clicks from toggling the video surface.
            }
    }
    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("弹幕设置").font(.headline)
                Toggle("显示弹幕", isOn: $danmaku.enabled)
                Toggle("画面字幕", isOn: $showSubtitles)
                if availableWidth <= 540 {
                    Picker(
                        "清晰度",
                        selection: Binding(
                            get: { model.qualityID }, set: { model.selectQuality($0) })
                    ) { ForEach(model.qualities) { Text($0.label).tag($0.value) } }
                }
                HStack {
                    Text("滚动")
                    Toggle("滚动", isOn: $rolling).labelsHidden()
                    Text("顶部 / 底部")
                    Toggle("固定", isOn: $fixed).labelsHidden()
                }
                Text("不透明度").font(.caption)
                Slider(value: $opacity, in: 0.2...1)
                Text("字号").font(.caption)
                Slider(value: $fontSize, in: 14...32, step: 1)
                Text("显示区域").font(.caption)
                Slider(value: $area, in: 0.25...1, step: 0.25)
                Text("弹幕速度").font(.caption)
                Slider(value: $dmSpeed, in: 0.5...2, step: 0.25)
                TextField("屏蔽关键词，用逗号分隔", text: $blocked).textFieldStyle(.roundedBorder)
                if let error = danmaku.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") {
                        danmaku.retry()
                        model.updateDanmaku()
                    }
                }
                Text(danmaku.loading ? "正在加载弹幕…" : "已加载 \(danmaku.comments.count) 条弹幕").font(
                    .caption
                ).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(width: 290, height: 420)
    }
    private func revealControls() {
        controls = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, model.playing, !scrubbing, !settings, !volumeSettings,
                !qualitySettings, !rateSettings
            else { return }
            withAnimation(.easeOut(duration: 0.2)) { controls = false }
        }
    }
    private func toggleFullscreen() {
        model.theater = true
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
