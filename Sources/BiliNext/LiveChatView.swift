import BiliNextCore
import SwiftUI

struct LiveChatView: View {
    @ObservedObject var chat: LiveChatModel
    @ObservedObject var session: LiveSession
    let close: () -> Void
    @State private var following = true
    @State private var userScrolling = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("弹幕").font(GlassTheme.bodyFont.weight(.semibold))
                Spacer()
                Button(action: chat.reconnect) {
                    Image(systemName: "arrow.clockwise").iconControlFrame()
                }.help("重新连接弹幕").accessibilityLabel("重新连接弹幕")
                Button(action: close) {
                    Image(systemName: "sidebar.right").iconControlFrame()
                }.help("收起弹幕列表").accessibilityLabel("收起弹幕列表")
            }.buttonStyle(InteractionButtonStyle()).padding(.horizontal, 12).padding(.top, 12)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: chat.connected ? "dot.radiowaves.left.and.right" : "wifi")
                Text(session.room?.isLive == false ? "主播暂未开播" : chat.status)
                Spacer()
            }.font(GlassTheme.captionFont).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { message in
                            LiveChatRow(message: message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(16)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 48
                } action: { _, atBottom in
                    if userScrolling || atBottom { following = atBottom }
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                }
                .onChange(of: chat.messages.last?.id) { _, _ in
                    if following { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .overlay {
                    if chat.messages.isEmpty {
                        ContentUnavailableView {
                            Label("等待弹幕", systemImage: "text.bubble")
                        } description: {
                            Text("直播间的新弹幕会显示在这里。")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if !following {
                        Button("回到最新弹幕", systemImage: "arrow.down") {
                            following = true
                            proxy.scrollTo("latest", anchor: .bottom)
                        }.buttonStyle(.glass).padding(12)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { DetailSurface() }
            .ignoresSafeArea(.container, edges: .top)
    }
}
