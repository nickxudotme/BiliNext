import AppKit
import SwiftUI

struct LivePlaybackView: View {
    @ObservedObject var session: LiveSession
    var isActive = true
    var chatVisible = true
    var toggleChat: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controls = true
    @State private var panelPresented = false
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var controlsVisible: Bool { controls || !session.playing || panelPresented }

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: togglePlayback) {
                ZStack {
                    Color.black
                    if let player = session.player {
                        MPVSurface(player: player).allowsHitTesting(false)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false)
                .accessibilityLabel(session.playing ? "暂停直播" : "播放直播")
                .disabled(session.room?.isLive != true)
            LiveDanmakuOverlay(
                chat: session.chat, playing: isActive && session.playing && !session.buffering)
            if let error = session.error {
                LivePlaybackStatus(
                    title: "直播连接中断", message: error, symbol: "wifi.exclamationmark",
                    retry: session.reload)
            } else if session.room?.isLive == false {
                LivePlaybackStatus(
                    title: "主播暂未开播", message: session.room?.author ?? "", symbol: "video.slash",
                    retry: session.reload)
            } else if session.loading || session.buffering {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            LivePlaybackControls(
                session: session, isActive: isActive, panelPresented: $panelPresented,
                togglePlayback: togglePlayback, toggleFullscreen: toggleFullscreen,
                chatVisible: chatVisible, toggleChat: toggleChat
            )
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
        }.background(.black)
            .focusable(isActive).focused($focused).focusEffectDisabled()
            .onContinuousHover { phase in if case .active = phase { revealControls() } }
            .onKeyPress(.space) {
                togglePlayback()
                return .handled
            }
            .onKeyPress("f") {
                toggleFullscreen()
                return .handled
            }
            .onAppear {
                focused = isActive
                revealControls()
            }
            .onChange(of: session.playing) { _, _ in revealControls() }
            .onChange(of: panelPresented) { _, _ in revealControls() }
            .onChange(of: isActive) { _, active in
                focused = active
                if active { revealControls() } else { hideTask?.cancel() }
            }
            .onDisappear { hideTask?.cancel() }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
    }

    private func togglePlayback() {
        session.togglePlayback()
        focused = isActive
        revealControls()
    }
    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
        revealControls()
    }
    private func revealControls() {
        hideTask?.cancel()
        controls = true
        guard isActive, session.playing, !panelPresented else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, isActive, session.playing, !panelPresented else { return }
            controls = false
        }
    }
}
