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
                        .font(GlassTheme.captionFont.weight(.semibold)).foregroundStyle(
                            .white.opacity(0.8))
                    Text(session.room?.author ?? "").font(GlassTheme.metadataFont).lineLimit(1)
                }
                Text(session.room?.title ?? "正在连接直播")
                    .font(GlassTheme.labelFont.weight(.medium)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                panel = .quality
            } label: {
                Text(session.qualities.first(where: { $0.id == session.quality })?.title ?? "画质")
                    .font(GlassTheme.metadataFont).padding(.horizontal, 6)
                    .frame(height: GlassTheme.controlHeight).contentShape(Rectangle())
            }.disabled(session.qualities.isEmpty).help("清晰度")
                .popover(isPresented: presentation(for: .quality)) {
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
                    .iconControlFrame()
            }.help(danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
                .accessibilityLabel(danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
            Button {
                panel = .danmaku
            } label: {
                Image(systemName: "slider.horizontal.3").iconControlFrame()
            }.help("画面弹幕设置").accessibilityLabel("画面弹幕设置")
                .popover(isPresented: presentation(for: .danmaku)) { LiveDanmakuSettings() }
            Button {
                panel = .volume
            } label: {
                Image(systemName: session.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                    .iconControlFrame()
            }.help("音量").accessibilityLabel("直播音量")
                .popover(isPresented: presentation(for: .volume)) {
                    Slider(value: $session.volume, in: 0...1).frame(width: 140).padding(20)
                        .accessibilityLabel("音量")
                }
            Button {
                panel = .options
            } label: {
                Image(systemName: "ellipsis").iconControlFrame()
            }.help("播放选项").accessibilityLabel("播放选项")
                .popover(isPresented: presentation(for: .options)) {
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
        }.font(.system(size: 18)).buttonStyle(InteractionButtonStyle()).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.top, 36).padding(.bottom, 14)
            .background {
                if reduceTransparency {
                    Color.black
                } else {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                }
            }
            .onChange(of: panel) { _, value in panelPresented = value != nil }
            .onChange(of: isActive) { _, active in if !active { panel = nil } }
            .onDisappear { panelPresented = false }
    }
    private func presentation(for value: Panel) -> Binding<Bool> {
        Binding(get: { panel == value }, set: { panel = $0 ? value : nil })
    }
}
