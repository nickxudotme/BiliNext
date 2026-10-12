import AppKit
import BiliNextCore
import Combine
import SwiftUI

struct VideoCardView: View {
    let video: Video
    @ObservedObject var model: AppModel
    let preview: HoverPreview
    var isActive: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var coverPixels = 640
    @State private var hovered = false
    @State private var previewing = false
    @Environment(\.cardGridScrolling) private var scrolling
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
                        ThumbnailView(url: video.cover, pixels: coverPixels) {
                            Image(systemName: "play.rectangle").font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                        if previewing && isActive {
                            VideoSurface(player: preview.player).allowsHitTesting(false)
                        }
                    }
                    .onGeometryChange(for: Int.self) { proxy in
                        // Bucket sizes to avoid new image tasks for every resize pixel.
                        max(64, Int(ceil(proxy.size.width * displayScale / 64)) * 64)
                    } action: { coverPixels = $0 }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.78)],
                            startPoint: .top, endPoint: .bottom
                        ).frame(height: 64)
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
                        VStack(alignment: .leading, spacing: 6) {
                            if previewing {
                                Label("静音预览", systemImage: "speaker.slash.fill")
                            } else {
                                HStack(spacing: 10) {
                                    if let count = video.viewCount {
                                        Label(formatted(count), systemImage: "play.fill")
                                    }
                                    if let count = video.danmakuCount {
                                        Label(formatted(count), systemImage: "text.bubble")
                                    }
                                }
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 10).padding(.bottom, 10)
                        .padding(.trailing, 64)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.artworkRadius))
                    .overlay { RoundedRectangle(cornerRadius: GlassTheme.artworkRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(2)
                        .frame(height: 40, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        ThumbnailView(url: video.avatar, pixels: 64) {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                        }.frame(width: 18, height: 18).clipShape(Circle())
                        Text(video.author).font(.system(size: 12))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
                if let viewed = video.viewedAt {
                    HStack {
                        Text(viewed, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        if let progress = video.progress {
                            Text(progress < 0 ? "已看完" : "看到 " + timestamp(progress))
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 6)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .overlay(alignment: .topTrailing) {
            if hovered && !scrolling {
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
                .chromeSurface(in: Circle(), interactive: true)
                .modifier(MenuHoverFeedback()).padding(8)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                .accessibilityLabel("视频选项")
            }
        }
        .onHover { inside in
            hovered = inside
            if inside && isActive && previewEnabled && !scrolling {
                preview.request(video)
            } else {
                preview.stop(ifMatching: video.id)
            }
        }
        .onReceive(preview.$activeID.combineLatest(preview.$ready)
            .map { $0 == video.id && $1 }.removeDuplicates()) { previewing = $0 }
        .onChange(of: scrolling) { _, moving in
            if moving { preview.stop(ifMatching: video.id) }
            else if hovered && isActive && previewEnabled { preview.request(video) }
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
