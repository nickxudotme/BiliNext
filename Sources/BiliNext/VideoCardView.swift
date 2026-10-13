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
    private var inWatchLater: Bool { model.menu == BrowseDestination.watchLater }

    var body: some View {
        Button {
            preview.stop()
            model.open(video, background: NSEvent.modifierFlags.contains(.command))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title).font(GlassTheme.bodyFont.weight(.medium))
                        .foregroundStyle(hovered && !scrolling ? GlassTheme.accent : .primary)
                        .lineSpacing(4).lineLimit(2)
                        .frame(height: VideoGridMetrics.titleHeight, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        ThumbnailView(url: video.avatar, pixels: 64) {
                            Image(systemName: "person.crop.circle.fill").resizable()
                                .foregroundStyle(.secondary)
                        }.frame(
                            width: VideoGridMetrics.authorAvatarSize,
                            height: VideoGridMetrics.authorAvatarSize
                        ).clipShape(Circle())
                        Text(video.author).foregroundStyle(.secondary).lineLimit(1)
                            .layoutPriority(1)
                        if let date = video.pubdate {
                            Text("· " + DisplayFormat.relativeDate(date))
                                .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    .font(GlassTheme.metadataFont)
                }
                .padding(.horizontal, 2).padding(.bottom, 6)
                if let viewed = video.viewedAt {
                    HStack(alignment: .top) {
                        Text(viewed, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        if let progress = video.progress {
                            Text(progress < 0 ? "已看完" : "看到 " + timestamp(progress))
                        }
                    }.font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(
                            height: VideoGridMetrics.historyMetadataHeight, alignment: .topLeading
                        )
                        .padding(.horizontal, 2).padding(.bottom, 6)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .overlay(alignment: .topTrailing) {
            if hovered && !scrolling {
                HStack(spacing: 6) {
                    Button {
                        preview.stop()
                        model.changeWatchLater(video, remove: inWatchLater)
                    } label: {
                        Image(systemName: inWatchLater ? "minus" : "clock")
                            .font(GlassTheme.labelFont.weight(.semibold))
                            .frame(width: 30, height: 30).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.libraryBusy.contains(video.id))
                    .help(inWatchLater ? "从稍后再看移除" : "稍后再看")
                    .accessibilityLabel(inWatchLater ? "从稍后再看移除" : "稍后再看")
                    .chromeSurface(in: Circle(), interactive: true)
                    Menu {
                        Button("在后台标签打开") {
                            preview.stop()
                            model.open(video, background: true)
                        }
                        Button(inWatchLater ? "从稍后再看移除" : "加入稍后再看") {
                            preview.stop()
                            model.changeWatchLater(video, remove: inWatchLater)
                        }.disabled(model.libraryBusy.contains(video.id))
                        Divider()
                        Toggle("悬停静音预览", isOn: $previewEnabled)
                    } label: {
                        Image(systemName: "ellipsis").font(GlassTheme.labelFont.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .chromeSurface(in: Circle(), interactive: true)
                        .accessibilityLabel("视频选项")
                }
                // Controls over artwork read as light glyphs on dark glass in both appearances.
                .environment(\.colorScheme, .dark).foregroundStyle(.white)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
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
        .onReceive(
            preview.$activeID.combineLatest(preview.$ready)
                .map { $0 == video.id && $1 }.removeDuplicates()
        ) { previewing = $0 }
        .onChange(of: scrolling) { _, moving in
            if moving {
                preview.stop(ifMatching: video.id)
            } else if hovered && isActive && previewEnabled {
                preview.request(video)
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
        .animation(Motion.standard(reduceMotion), value: hovered)
        .contextMenu {
            Button("在后台标签打开") {
                preview.stop()
                model.open(video, background: true)
            }
            Button(inWatchLater ? "从稍后再看移除" : "加入稍后再看") {
                preview.stop()
                model.changeWatchLater(video, remove: inWatchLater)
            }.disabled(model.libraryBusy.contains(video.id))
        }
    }

    private var lifted: Bool { hovered && !scrolling && !reduceMotion }

    /// Artwork with stats, duration and history progress. Hover deepens its shadow and
    /// gently zooms the image inside the rounded frame.
    private var cover: some View {
        Color.primary.opacity(0.045).aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                ThumbnailView(url: video.cover, pixels: coverPixels) {
                    Image(systemName: "play.rectangle").font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                }
                .scaleEffect(lifted ? 1.04 : 1)
                if previewing && isActive {
                    VideoSurface(player: preview.player).allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: Int.self) { proxy in
                // Bucket sizes to avoid new image tasks for every resize pixel.
                max(64, Int(ceil(proxy.size.width * displayScale / 64)) * 64)
            } action: {
                coverPixels = $0
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 56)
                .opacity(previewing ? 0 : 1)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
                    if previewing {
                        Label("静音预览", systemImage: "speaker.slash.fill")
                    } else {
                        if let count = video.viewCount {
                            Label(DisplayFormat.count(count), systemImage: "play.fill")
                        }
                        if let count = video.danmakuCount {
                            Label(DisplayFormat.count(count), systemImage: "text.bubble")
                        }
                    }
                    Spacer(minLength: 0)
                    if let duration = video.duration, duration > 0, !previewing {
                        Text(timestamp(duration)).monospacedDigit()
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(GlassTheme.captionFont.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(.horizontal, 10).padding(.bottom, historyProgress == nil ? 8 : 11)
            }
            .overlay(alignment: .bottomLeading) {
                if let historyProgress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.28))
                            Rectangle().fill(GlassTheme.accent)
                                .frame(width: proxy.size.width * historyProgress)
                        }
                        .frame(height: 3).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.artworkRadius))
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.artworkRadius).strokeBorder(
                    .primary.opacity(0.08), lineWidth: 1
                ).allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 14 : 0,
                y: lifted ? 8 : 0)
    }

    /// Watched fraction for history cards; finished videos (negative progress) read as full.
    private var historyProgress: Double? {
        guard video.viewedAt != nil, let progress = video.progress else { return nil }
        if progress < 0 { return 1 }
        guard let duration = video.duration, duration > 0 else { return nil }
        return min(1, progress / duration)
    }
}

/// Icon and number close together, as on Bilibili's cover stats.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
