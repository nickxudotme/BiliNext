import AppKit
import BiliNextCore
import SwiftUI

/// One action: an icon over its count or name, pink once the account has done it.
struct VideoActionLabel: View {
    let title: String
    let systemImage: String
    var active = false
    var bounce = 0

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 21, weight: .medium))
                .frame(height: 28)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
            Text(title).font(GlassTheme.captionFont.weight(.medium)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? GlassTheme.accent : .primary)
        .frame(minWidth: 44, minHeight: 58)
        .contentShape(Rectangle())
    }
}

/// 点赞 · 投币 · 收藏 · 稍后 · 缓存 · 分享, as on the official video page. Holding 点赞 for
/// 0.8 s performs 一键三连 with a filling ring, like the official client's long press.
struct VideoActionBar: View {
    @ObservedObject var model: AppModel
    let video: Video
    @State private var pressing = false
    @State private var pressStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stats: VideoStats { model.detail?.stats ?? VideoStats() }
    private var episode: Bool { video.episodeID != nil }

    var body: some View {
        HStack(spacing: 4) {
            if !episode {
                likeButton
                Button {
                    model.requestCoin()
                } label: {
                    VideoActionLabel(
                        title: stats.coins.map(DisplayFormat.count) ?? "投币",
                        systemImage: model.relation.coins > 0 ? "c.circle.fill" : "c.circle",
                        active: model.relation.coins > 0, bounce: model.tripleCount)
                }
                .help(model.relation.coins > 0 ? "已投 \(model.relation.coins) 枚硬币" : "投币 · W")
                .accessibilityLabel("投币")
                .disabled(model.interactionBusy || model.relation.coins >= 2)
            }
            Button {
                model.requestFavorite()
            } label: {
                VideoActionLabel(
                    title: stats.favorites.map(DisplayFormat.count) ?? "收藏",
                    systemImage: model.relation.favorited ? "star.fill" : "star",
                    active: model.relation.favorited, bounce: model.tripleCount)
            }
            .help("收藏到文件夹 · E").accessibilityLabel("收藏")
            .disabled(video.aid == nil)
            Button {
                model.changeWatchLater(video)
            } label: {
                VideoActionLabel(title: "稍后", systemImage: "clock")
            }
            .help("加入稍后再看").accessibilityLabel("加入稍后再看")
            .disabled(model.libraryBusy.contains(video.id))
            Button {
                if let cid = model.pageID {
                    model.downloads.start(
                        video: video, cid: cid, quality: model.qualityID, api: model.api)
                    model.downloadsPresented = true
                }
            } label: {
                VideoActionLabel(title: "缓存", systemImage: "arrow.down.circle")
            }
            .help("缓存当前分 P").accessibilityLabel("缓存当前分 P").disabled(model.pageID == nil)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "https://www.bilibili.com/video/\(video.bvid)?t=\(Int(model.time))",
                    forType: .string)
                model.toast = "已复制当前时间链接"
            } label: {
                VideoActionLabel(
                    title: stats.shares.map(DisplayFormat.count) ?? "分享", systemImage: "link")
            }
            .help("复制当前时间链接").accessibilityLabel("复制当前时间链接")
        }
        .buttonStyle(InteractionButtonStyle())
        .frame(maxWidth: .infinity)
        .task(id: "\(video.bvid):\(model.profile?.id ?? 0)") { model.loadRelation(for: video.bvid) }
    }

    /// A click toggles the like; holding fills a ring and fires 一键三连 when it closes.
    private var likeButton: some View {
        VideoActionLabel(
            title: stats.likes.map(DisplayFormat.count) ?? "点赞",
            systemImage: model.relation.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            active: model.relation.liked, bounce: model.tripleCount
        )
        .overlay(alignment: .top) {
            Circle()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(GlassTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 38, height: 38)
                .offset(y: -5)
                .opacity(pressing ? 1 : 0)
                .animation(pressing ? .linear(duration: 0.8) : Motion.quick, value: pressing)
                .allowsHitTesting(false)
        }
        .scaleEffect(pressing && !reduceMotion ? 0.94 : 1)
        .animation(Motion.quick(reduceMotion), value: pressing)
        .modifier(PointerFeedback())
        .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 12) {
            pressing = false
            model.triple()
        } onPressingChanged: { down in
            guard !model.interactionBusy else { return }
            if down {
                pressStart = Date()
                pressing = true
            } else {
                pressing = false
                // Releasing well before the ring closes is an ordinary click. Timing decides,
                // because SwiftUI does not order this callback against the completed press.
                if let start = pressStart, Date().timeIntervalSince(start) < 0.7 {
                    model.toggleLike()
                }
                pressStart = nil
            }
        }
        .help(model.relation.liked ? "取消点赞 · Q（长按一键三连）" : "点赞 · Q（长按一键三连）")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.relation.liked ? "取消点赞" : "点赞")
        .accessibilityAction { model.toggleLike() }
        .accessibilityAction(named: "一键三连") { model.triple() }
    }
}

/// The shared hover wash for views that handle their own gestures instead of being buttons.
private struct PointerFeedback: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                    .fill(.primary.opacity(hovered ? GlassTheme.hoverOpacity : 0))
            }
            .onHover { hovered = $0 }
            .animation(Motion.quick(reduceMotion), value: hovered)
    }
}
