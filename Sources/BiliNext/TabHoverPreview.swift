import BiliNextCore
import SwiftUI

/// Hover cards for sidebar tabs, timed like Arc's: the first card waits 200 ms, then
/// moving to a neighbouring row switches the card at once until the pointer leaves the tabs.
@MainActor
final class TabHoverPreview: ObservableObject {
    @Published private(set) var tabID: String?
    private var hovered: String?
    private var committed = false
    private var task: Task<Void, Never>?
    private let delay: Duration
    private let grace: Duration

    init(delay: Duration = .milliseconds(200), grace: Duration = .milliseconds(120)) {
        self.delay = delay
        self.grace = grace
    }

    func hover(_ id: String, inside: Bool) {
        if inside {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
        task?.cancel()
        if let target = hovered {
            if committed {
                tabID = target
                return
            }
            task = Task { [delay] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                committed = true
                tabID = target
            }
        } else {
            // A short grace keeps the card while the pointer crosses the gap between rows.
            task = Task { [grace] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                committed = false
                tabID = nil
            }
        }
    }

    func dismiss() {
        task?.cancel()
        hovered = nil
        committed = false
        tabID = nil
    }
}

/// Each tab row's bounds, so the shell can place the card beside the hovered row.
struct TabRowAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

/// A floating card with a large cover, title, UP and where the tab will resume.
struct TabPreviewCard: View {
    let tab: SessionTab
    static let width: CGFloat = 300

    private var live: Bool { LiveSession.roomID(tab.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThumbnailView(url: tab.video.cover, pixels: 640) {
                Rectangle().fill(.primary.opacity(0.06))
            }
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(width: Self.width - 20, height: (Self.width - 20) * 9 / 16)
            .clipped()
            .overlay(alignment: .bottom) { progressBar }
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
            VStack(alignment: .leading, spacing: 6) {
                Text(tab.video.title).font(GlassTheme.labelFont.weight(.semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(tab.video.author).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(status).monospacedDigit().foregroundStyle(live ? .red : .secondary)
                }
                .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: Self.width)
        .chromeSurface(in: RoundedRectangle(cornerRadius: GlassTheme.panelRadius))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var status: String {
        if live { return "直播中" }
        let duration = tab.video.duration ?? 0
        if tab.position > 0, duration > 0 {
            return "看到 \(timestamp(tab.position)) / \(timestamp(duration))"
        }
        return duration > 0 ? timestamp(duration) : ""
    }

    @ViewBuilder private var progressBar: some View {
        if let duration = tab.video.duration, duration > 0, tab.position > 0 {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.28))
                    Rectangle().fill(GlassTheme.accent)
                        .frame(width: proxy.size.width * min(1, tab.position / duration))
                }
            }
            .frame(height: 3)
        }
    }
}
