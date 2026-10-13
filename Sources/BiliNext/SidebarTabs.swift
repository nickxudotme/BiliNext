import AppKit
import BiliNextCore
import SwiftUI

/// The open video tabs below the sidebar navigation, modelled on Arc's Today section:
/// cover thumbnails with watch progress, a selected row that is a piece of the content card,
/// close only on hover, and a hover-only clear action beside the divider.
struct SidebarTabList: View {
    @ObservedObject var model: AppModel
    /// The pointer is over the sidebar, which reveals the clear action.
    let sidebarHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                if sidebarHovered && !model.tabs.isEmpty {
                    Button {
                        model.clearTabs()
                    } label: {
                        Label("清除", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon).font(GlassTheme.captionFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).frame(height: 22)
                    }
                    .buttonStyle(InteractionButtonStyle())
                    .help(model.selected == nil ? "清除打开的标签，可撤销" : "清除其他标签，保留当前视频，可撤销")
                    .transition(.opacity)
                }
            }
            .frame(height: 24).padding(.horizontal, 14)
            .animation(Motion.quick(reduceMotion), value: sidebarHovered)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        SidebarTabRow(
                            tab: tab, selected: model.selected == tab.id,
                            playing: model.isPlaying(tab.id),
                            unseen: model.unseenTabs.contains(tab.id), model: model
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .animation(Motion.standard(reduceMotion), value: model.tabs.map(\.id))
            }
            if !model.closed.isEmpty {
                Button {
                    model.undoClose()
                } label: {
                    Label(
                        model.closed.count > 1 ? "恢复 \(model.closed.count) 个标签" : "恢复关闭的标签",
                        systemImage: "arrow.uturn.backward"
                    )
                    .font(GlassTheme.labelFont).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(
                        maxWidth: .infinity, minHeight: GlassTheme.tabRowHeight, alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(InteractionButtonStyle(kind: .row))
                .keyboardShortcut("z", modifiers: .command)
                .padding(.horizontal, 8).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .animation(Motion.standard(reduceMotion), value: model.closed.isEmpty)
    }
}

private struct SidebarTabRow: View {
    let tab: SessionTab
    let selected: Bool
    let playing: Bool
    let unseen: Bool
    @ObservedObject var model: AppModel
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { LiveSession.roomID(tab.id) != nil }
    private var progress: Double? {
        guard let duration = tab.video.duration, duration > 0, tab.position > 0 else { return nil }
        return min(1, tab.position / duration)
    }

    var body: some View {
        Button {
            model.activate(tab.id, autoplay: true)
        } label: {
            HStack(spacing: 9) {
                cover
                Text(tab.video.title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected || hovered ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // On hover the title fades out under the close button instead of reflowing.
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: hovered ? 34 : 0)
                        }
                    }
                if !hovered && playing {
                    Image(systemName: "waveform")
                        .font(GlassTheme.smallIconFont).foregroundStyle(GlassTheme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        .frame(width: 18).accessibilityLabel("正在播放")
                } else if !hovered && unseen {
                    Circle().fill(GlassTheme.accent).frame(width: 7, height: 7)
                        .frame(width: 18).accessibilityLabel("未看")
                }
            }
            .font(GlassTheme.labelFont.weight(selected ? .medium : .regular))
            .padding(.leading, 6).padding(.trailing, 5)
            .frame(height: GlassTheme.tabRowHeight)
            .contentShape(Rectangle())
            .background { NavigationSelection(selected: selected) }
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .overlay(alignment: .trailing) {
            if hovered {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark").font(GlassTheme.smallIconFont)
                        .iconControlFrame(size: 22)
                }
                .buttonStyle(InteractionButtonStyle())
                .help("关闭标签").accessibilityLabel("关闭 \(tab.video.title)")
                .padding(.trailing, 5)
            }
        }
        .onHover { hovered = $0 }
        .animation(Motion.quick(reduceMotion), value: hovered)
        .accessibilityLabel(tab.video.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(tab.video.title)
        .contextMenu {
            Button("关闭标签") { model.close(tab.id) }
            Button("关闭其他标签") { model.closeOtherTabs(keeping: tab.id) }
                .disabled(model.tabs.count < 2)
            Button("关闭下方标签") { model.closeOtherTabs(keeping: tab.id, onlyBelow: true) }
                .disabled(model.tabs.last?.id == tab.id)
            Divider()
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    LiveSession.roomID(tab.id).map { "https://live.bilibili.com/\($0)" }
                        ?? "https://www.bilibili.com/video/\(tab.id)",
                    forType: .string)
            }
        }
    }

    /// A small 16:9 cover keeps tabs recognisable; progress and live state sit on its edge.
    private var cover: some View {
        ThumbnailView(url: tab.video.cover, pixels: 96) {
            Rectangle().fill(.primary.opacity(0.08))
        }
        .frame(width: 38, height: 22)
        .overlay(alignment: .bottomLeading) {
            if let progress {
                GeometryReader { proxy in
                    Rectangle().fill(GlassTheme.accent)
                        .frame(width: proxy.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if live {
                Circle().fill(.red).frame(width: 6, height: 6)
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                    .padding(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}
