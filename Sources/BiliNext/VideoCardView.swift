import AppKit
import BiliNextCore
import SwiftUI

struct VideoCardView: View {
    let video: Video
    @ObservedObject var model: AppModel
    @ObservedObject var preview: HoverPreview
    var isActive: Bool
    @State private var hovered = false
    @AppStorage("cards.hoverPreview") private var previewEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            preview.stop()
            model.open(video, background: NSEvent.modifierFlags.contains(.command))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Color.primary.opacity(0.045).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: video.cover) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "play.rectangle").font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                        if preview.activeID == video.id && preview.ready && isActive {
                            VideoSurface(player: preview.player).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        ).frame(height: 45)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = video.duration, duration > 0 {
                            Text(timestamp(duration)).font(.system(size: 11, weight: .medium))
                                .monospacedDigit().padding(.horizontal, 6).padding(.vertical, 3)
                                .background(
                                    .black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)
                                )
                                .padding(8).foregroundStyle(.white)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if preview.activeID == video.id && preview.ready {
                            Label("静音预览", systemImage: "speaker.slash.fill")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                                .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(alignment: .top, spacing: 8) {
                    AvatarView(url: video.avatar).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.title).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary).lineLimit(2)
                            .frame(height: 38, alignment: .topLeading)
                        Text(video.author).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            if let count = video.viewCount {
                                Label(formatted(count), systemImage: "play.rectangle")
                            }
                            if let count = video.danmakuCount {
                                Label(formatted(count), systemImage: "text.bubble")
                            }
                        }.font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                if let viewed = video.viewedAt {
                    HStack {
                        Text(viewed, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        if let progress = video.progress {
                            Text(progress < 0 ? "已看完" : "看到 " + timestamp(progress))
                        }
                    }.font(.caption2).foregroundStyle(.tertiary)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("在后台标签打开") {
                    preview.stop()
                    model.open(video, background: true)
                }
                Button(model.menu == "稍后再看" ? "从稍后再看移除" : "加入稍后再看") {
                    preview.stop()
                    model.changeWatchLater(video, remove: model.menu == "稍后再看")
                }.disabled(model.libraryBusy.contains(video.id))
                Divider()
                Toggle("悬停静音预览", isOn: $previewEnabled)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .glassEffect(.regular.interactive(), in: Circle())
                .modifier(MenuHoverFeedback()).padding(8)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                .accessibilityLabel("视频选项")
        }
        .onHover { inside in
            hovered = inside
            if inside && isActive && previewEnabled {
                preview.request(video)
            } else {
                preview.stop(ifMatching: video.id)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                hovered = false
                preview.stop(ifMatching: video.id)
            }
        }
        .onChange(of: previewEnabled) { _, enabled in
            if !enabled { preview.stop(ifMatching: video.id) }
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if !visible { preview.stop(ifMatching: video.id) }
        }
        .onDisappear { preview.stop(ifMatching: video.id) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .contextMenu {
            Button("在后台标签打开") {
                preview.stop()
                model.open(video, background: true)
            }
            Button(model.menu == "稍后再看" ? "从稍后再看移除" : "加入稍后再看") {
                preview.stop()
                model.changeWatchLater(video, remove: model.menu == "稍后再看")
            }.disabled(model.libraryBusy.contains(video.id))
        }
    }

    private func formatted(_ count: String) -> String {
        guard let value = Double(count) else { return count }
        if value >= 100_000_000 { return String(format: "%.1f亿", value / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", value / 10_000) }
        return count
    }
}
