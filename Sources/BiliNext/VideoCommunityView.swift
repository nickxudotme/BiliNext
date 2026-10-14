import BiliNextCore
import SwiftUI

/// 接着看: videos related to the open one. ⌘-click opens a background tab.
struct VideoCommunityView: View {
    @ObservedObject var model: AppModel
    let section: String
    @State private var related: [Video] = []
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接着看").font(GlassTheme.sectionTitleFont)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(related) { video in
                        RelatedVideoRow(video: video) {
                            model.open(video, background: NSEvent.modifierFlags.contains(.command))
                        }
                    }
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let error {
                        ErrorBanner(message: error) { load() }
                    } else if related.isEmpty {
                        ContentUnavailableView("暂无相关推荐", systemImage: "play.rectangle")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
        .padding(16)
        .task(id: model.detail?.video.bvid) { load() }
    }

    private func load() {
        guard let video = model.detail?.video else { return }
        let token = UUID()
        generation = token
        related = []
        error = nil
        loading = true
        Task {
            do {
                let result = try await model.api.related(bvid: video.bvid)
                guard token == generation else { return }
                related = result
            } catch {
                guard token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { loading = false }
        }
    }
}

private struct RelatedVideoRow: View {
    let video: Video
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                ThumbnailView(url: video.cover, pixels: 320) { Color.primary.opacity(0.06) }
                    .frame(width: 128, height: 72).clipped()
                    .overlay(alignment: .bottomTrailing) { duration }
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title).font(GlassTheme.labelFont.weight(.medium))
                        .lineSpacing(3).lineLimit(2)
                    Text(video.author).font(GlassTheme.metadataFont)
                        .foregroundStyle(.secondary).lineLimit(1)
                    if let views = video.viewCount {
                        Label(DisplayFormat.count(views), systemImage: "play")
                            .font(GlassTheme.captionFont).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }.padding(4).contentShape(Rectangle())
        }.buttonStyle(InteractionButtonStyle(kind: .row))
    }

    @ViewBuilder private var duration: some View {
        if let duration = video.duration, duration > 0 {
            Text(timestamp(duration))
                .font(GlassTheme.captionFont.weight(.medium)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    .black.opacity(0.55), in: RoundedRectangle(cornerRadius: GlassTheme.badgeRadius)
                )
                .padding(4)
        }
    }
}
