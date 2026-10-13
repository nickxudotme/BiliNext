import SwiftUI

struct LivePlaybackControls: View {
    @ObservedObject var session: LiveSession
    let isActive: Bool
    @Binding var panelPresented: Bool
    let togglePlayback: () -> Void
    let toggleFullscreen: () -> Void
    let chatVisible: Bool
    let toggleChat: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("danmaku.enabled") private var danmakuEnabled = true
    @State private var panel: Panel?
    private enum Panel { case quality, volume, options, danmaku }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: session.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20)).iconControlFrame()
            }.disabled(session.room?.isLive != true)
                .accessibilityLabel(session.playing ? "暂停" : "播放").help("播放／暂停 · 空格")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Label("直播", systemImage: "dot.radiowaves.left.and.right")
                        .font(GlassTheme.captionFont.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red.opacity(0.85), in: Capsule())
                    Text(session.room?.author ?? "").font(GlassTheme.metadataFont).lineLimit(1)
                }
                Text(session.room?.title ?? "正在连接直播")
                    .font(GlassTheme.labelFont.weight(.medium)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                panel = .quality
            } label: {
                Text(session.qualities.first(where: { $0.id == session.quality })?.title ?? "画质")
                    .font(GlassTheme.labelFont.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(panel == .quality ? GlassTheme.accent : .white)
                    .padding(.horizontal, 8).frame(minHeight: GlassTheme.iconControlSize)
                    .contentShape(Rectangle())
            }.disabled(session.qualities.isEmpty).help("清晰度")
                .popover(isPresented: presentation(for: .quality), arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("清晰度").font(GlassTheme.bodyFont.weight(.semibold))
                        ForEach(session.qualities) { quality in
                            PlayerOptionRow(
                                title: quality.title, selected: quality.id == session.quality
                            ) {
                                session.selectQuality(quality.id)
                                panel = nil
                            }
                        }
                    }.padding(12).frame(width: 210)
                }
            Button {
                danmakuEnabled.toggle()
            } label: {
                Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                    .foregroundStyle(danmakuEnabled ? GlassTheme.accent : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .iconControlFrame()
            }.help(danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
                .accessibilityLabel(danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
            Button {
                panel = .danmaku
            } label: {
                Image(systemName: "slider.horizontal.3").iconControlFrame()
            }.help("画面弹幕设置").accessibilityLabel("画面弹幕设置")
                .popover(isPresented: presentation(for: .danmaku), arrowEdge: .top) {
                    LiveDanmakuSettings()
                }
            Button {
                panel = .volume
            } label: {
                Image(systemName: volumeSymbol).contentTransition(.symbolEffect(.replace))
                    .iconControlFrame()
            }.help("音量").accessibilityLabel("直播音量")
                .popover(isPresented: presentation(for: .volume), arrowEdge: .top) {
                    Slider(value: $session.volume, in: 0...1).frame(width: 140).padding(20)
                        .accessibilityLabel("音量")
                }
            Button {
                panel = .options
            } label: {
                Image(systemName: "ellipsis").iconControlFrame()
            }.help("播放选项").accessibilityLabel("播放选项")
                .popover(isPresented: presentation(for: .options), arrowEdge: .top) {
                    PlayerOptionRow(title: "重新连接", selected: false) {
                        panel = nil
                        session.reload()
                    }.padding(8).frame(width: 180)
                }
            Button(action: toggleFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").iconControlFrame()
            }.help("全屏 · F").accessibilityLabel("全屏")
            Button(action: toggleChat) {
                Image(systemName: "sidebar.right").iconControlFrame()
            }.help(chatVisible ? "收起弹幕列表" : "展开弹幕列表")
                .accessibilityLabel(chatVisible ? "收起弹幕列表" : "展开弹幕列表")
        }.font(.system(size: 17, weight: .medium)).buttonStyle(InteractionButtonStyle())
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.top, 44).padding(.bottom, 12)
            .background {
                if reduceTransparency {
                    Color.black
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.45), location: 0.45),
                            .init(color: .black.opacity(0.82), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                }
            }
            // Same dark controls as on-demand playback, in both appearances.
            .environment(\.colorScheme, .dark)
            .onChange(of: panel) { _, value in panelPresented = value != nil }
            .onChange(of: isActive) { _, active in if !active { panel = nil } }
            .onDisappear { panelPresented = false }
    }
    private var volumeSymbol: String {
        switch session.volume {
        case ...0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private func presentation(for value: Panel) -> Binding<Bool> {
        Binding(get: { panel == value }, set: { panel = $0 ? value : nil })
    }
}
