import AppKit
import BiliNextCore
import SwiftUI

/// The 简介 panel in the official client's order, in one scroll: UP, title and stats with a
/// collapsible description, actions, the 合集 or 分P list, then related videos.
struct VideoIntroPanel: View {
    @ObservedObject var model: AppModel
    @State private var memberPresented = false
    @State private var showsTop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if let detail = model.detail {
                        content(detail)
                    } else if let error = model.playerError, !model.videoLoading {
                        ErrorBanner(message: error) {
                            if let id = model.selected { model.activate(id, force: true) }
                        }
                        .padding(20)
                    } else {
                        IntroSkeleton().padding(20)
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y > 200
            } action: {
                _, value in
                showsTop = value
            }
            .overlay(alignment: .bottomTrailing) {
                if showsTop {
                    Button {
                        withAnimation(Motion.emphasized(reduceMotion)) { proxy.scrollTo("top") }
                    } label: {
                        Image(systemName: "arrow.up").font(GlassTheme.iconFont.weight(.semibold))
                            .iconControlFrame(size: 40)
                    }
                    .buttonStyle(InteractionButtonStyle())
                    .chromeSurface(in: Circle(), interactive: true)
                    .help("回到顶部").accessibilityLabel("回到顶部")
                    .padding(16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(Motion.standard(reduceMotion), value: showsTop)
            .onChange(of: model.detail?.video.bvid) { _, _ in proxy.scrollTo("top") }
        }
        .environment(\.openURL, OpenURLAction(handler: open))
        .environment(\.videoDuration, model.duration)
        .sheet(isPresented: $memberPresented) {
            if let video = model.detail?.video, let mid = video.ownerID {
                MemberView(model: model, mid: mid, name: video.author)
            }
        }
    }

    @ViewBuilder private func content(_ detail: VideoDetail) -> some View {
        let video = detail.video
        VStack(alignment: .leading, spacing: 0) {
            UploaderCard(video: video, extras: detail.extras) { memberPresented = true }
                .padding(.top, 16).padding(.bottom, 18)
            IntroDetails(detail: detail)
            VideoActionBar(model: model, video: video).padding(.top, 14)
            Divider().opacity(0.6).padding(.top, 10)
            if let season = detail.extras.season {
                SeasonList(model: model, season: season, current: video.bvid)
                    .padding(.top, 18)
            } else if detail.pages.count > 1 {
                PageList(model: model, pages: detail.pages).padding(.top, 18)
            }
        }
        .padding(.horizontal, 20)
        if !detail.extras.related.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().opacity(0.6).padding(.horizontal, 20).padding(.bottom, 16)
                GroupHeader(title: "相关推荐", detail: nil).padding(.horizontal, 20)
                ForEach(detail.extras.related) { related in
                    RelatedVideoRow(video: related) {
                        model.open(related, background: NSEvent.modifierFlags.contains(.command))
                    }
                }
            }
            .padding(.top, 18).padding(.bottom, 16)
        }
    }

    /// Timestamps in the description seek; BV IDs open videos (⌘ for a background tab).
    private func open(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == CommentLinks.scheme else { return .systemAction }
        let value = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "seek":
            if let seconds = Double(value) {
                model.seek(seconds)
                model.toast = "跳到 " + timestamp(seconds)
            }
        case "video":
            let background = NSEvent.modifierFlags.contains(.command)
            Task {
                do {
                    model.open(try await model.api.detail(value).video, background: background)
                } catch { model.toast = error.localizedDescription }
            }
        case "search": model.search(value)
        default: break
        }
        return .handled
    }
}

// MARK: - Uploader

private struct UploaderCard: View {
    let video: Video
    let extras: VideoExtras
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                AvatarView(url: video.avatar).frame(width: 44, height: 44)
                    .overlay { Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.author).font(GlassTheme.labelFont.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let followers = extras.uploaderFollowers {
                            Text("\(DisplayFormat.count(followers))粉丝")
                        }
                        if extras.uploaderFollowers != nil && extras.uploaderVideos != nil {
                            Circle().frame(width: 2, height: 2)
                        }
                        if let videos = extras.uploaderVideos {
                            Text("\(DisplayFormat.count(videos))投稿")
                        }
                        if extras.uploaderFollowers == nil && extras.uploaderVideos == nil {
                            Text("查看 UP 主主页")
                        }
                    }
                    .font(GlassTheme.captionFont).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Text("主页")
                    Image(systemName: "chevron.right").font(GlassTheme.smallIconFont)
                }
                .font(GlassTheme.metadataFont.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(.white.opacity(0.08), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .disabled(video.ownerID == nil)
        .accessibilityLabel("UP 主 \(video.author)")
    }
}

// MARK: - Title, stats and description

struct IntroDetails: View {
    let detail: VideoDetail
    @State private var expanded: Bool

    init(detail: VideoDetail, expanded: Bool = false) {
        self.detail = detail
        self._expanded = State(initialValue: expanded)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var video: Video { detail.video }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(video.title).font(.system(size: 20, weight: .semibold)).lineSpacing(3)
                    .lineLimit(expanded ? nil : 2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(Motion.standard(reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text(expanded ? "收起" : "展开")
                        Image(systemName: "chevron.down").font(GlassTheme.smallIconFont)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    .padding(.top, 2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起简介" : "展开简介")
            }
            stats
            if !detail.extras.honors.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.extras.honors.prefix(2), id: \.self) { honor in
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill").foregroundStyle(.orange)
                            Text(honor).foregroundStyle(.secondary)
                        }
                        .font(GlassTheme.captionFont.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.06), in: Capsule())
                        .lineLimit(1)
                    }
                }
            }
            if expanded { more.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .onChange(of: video.bvid) { _, _ in expanded = false }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            if let views = video.viewCount {
                Label(DisplayFormat.count(views), systemImage: "play.rectangle")
            }
            if let danmaku = video.danmakuCount {
                Label(DisplayFormat.count(danmaku), systemImage: "text.bubble")
            }
            if let date = video.pubdate {
                Label(
                    date.formatted(
                        .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()),
                    systemImage: "clock")
            }
        }
        .labelStyle(StatLabelStyle())
        .font(GlassTheme.captionFont).foregroundStyle(.secondary).monospacedDigit()
        .lineLimit(1)
    }

    /// BV, partition, rights, tags and the description, revealed by 展开 as in the official
    /// client.
    private var more: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(video.bvid).textSelection(.enabled)
                if !detail.extras.partition.isEmpty { Text(detail.extras.partition) }
                if !detail.extras.original { Text("转载") }
                if detail.extras.noReprint {
                    Label("未经作者授权，禁止转载", systemImage: "nosign").labelStyle(StatLabelStyle())
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            .font(GlassTheme.captionFont).foregroundStyle(.secondary).lineLimit(1)
            if !detail.description.isEmpty {
                CommentText(segments: CommentSegment.split(text: detail.description))
                    .font(GlassTheme.labelFont).lineSpacing(4).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.extras.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(detail.extras.tags, id: \.self) { tag in
                        Link(destination: CommentLinks.search(tag)) {
                            Text(tag).font(GlassTheme.captionFont)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("搜索「\(tag)」")
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct StatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

// MARK: - 合集 and 分P

/// A native group heading: a quiet label, with an optional position on the right.
private struct GroupHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(GlassTheme.metadataFont.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).font(GlassTheme.captionFont).foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.bottom, 8)
    }
}

/// A soft card holding a scrollable list, shared by 合集 and 分P.
private struct ListCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
    }
}

/// One row in 合集 and 分P lists: the current item is lifted, with a pink waveform.
private struct EpisodeRow: View {
    let title: String
    let duration: Double
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if current {
                    Image(systemName: "waveform").font(GlassTheme.smallIconFont)
                        .foregroundStyle(GlassTheme.accent)
                }
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(current ? 1 : 0.85)
                if duration > 0 {
                    Text(timestamp(duration)).font(GlassTheme.captionFont).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(GlassTheme.labelFont.weight(current ? .semibold : .regular))
            .padding(.horizontal, 10).frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                    .fill(GlassTheme.raisedFill.opacity(current ? 1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }
}

private struct SeasonList: View {
    @ObservedObject var model: AppModel
    let season: VideoSeason
    let current: String
    @State private var sectionID: Int64?

    private var episodes: [VideoSeason.Episode] { season.sections.flatMap(\.episodes) }
    private var position: Int? { episodes.firstIndex { $0.bvid == current }.map { $0 + 1 } }
    private var section: VideoSeason.Section? {
        season.sections.first { $0.id == sectionID }
            ?? season.sections.first { $0.episodes.contains { $0.bvid == current } }
            ?? season.sections.first
    }

    var body: some View {
        ListCard {
            GroupHeader(
                title: "合集",
                detail: "\(position.map(String.init) ?? "-") / \(season.episodeCount)"
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(season.title).font(GlassTheme.bodyFont.weight(.semibold)).lineLimit(1)
                if let views = season.views {
                    Text("\(DisplayFormat.count(views))次播放").font(GlassTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            if season.sections.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(season.sections) { item in
                            let selected = item.id == section?.id
                            Button {
                                sectionID = item.id
                            } label: {
                                Text(item.title)
                                    .font(
                                        GlassTheme.metadataFont.weight(
                                            selected ? .semibold : .regular)
                                    )
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(
                                        GlassTheme.raisedFill.opacity(selected ? 1 : 0),
                                        in: Capsule())
                            }
                            .buttonStyle(InteractionButtonStyle(kind: .row))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 6)
            }
            if let section {
                EpisodeScroll(
                    ids: section.episodes.map(\.bvid), current: current,
                    maxHeight: season.sections.count > 1 ? 180 : 216
                ) { _ in
                    ForEach(section.episodes) { episode in
                        EpisodeRow(
                            title: episode.title, duration: episode.duration,
                            current: episode.bvid == current
                        ) { play(episode) }
                        .id(episode.bvid)
                    }
                }
            }
        }
    }

    /// Episodes play in this tab, like moving through a series; ⌘ opens a background tab.
    private func play(_ episode: VideoSeason.Episode) {
        guard episode.bvid != current else { return }
        let video = Video(
            bvid: episode.bvid, title: episode.title, author: episode.author,
            cover: episode.cover, aid: episode.aid, duration: episode.duration,
            viewCount: episode.views.map(String.init), pubdate: episode.pubdate)
        if NSEvent.modifierFlags.contains(.command) {
            model.open(video, background: true)
        } else if let id = model.selected {
            model.replace(id, with: video)
        }
    }
}

private struct PageList: View {
    @ObservedObject var model: AppModel
    let pages: [VideoPage]
    @AppStorage("intro.pageGrid") private var grid = false

    private var position: Int? { pages.firstIndex { $0.cid == model.pageID }.map { $0 + 1 } }

    var body: some View {
        ListCard {
            HStack(spacing: 6) {
                GroupHeader(
                    title: "视频选集",
                    detail: "\(position.map(String.init) ?? "-") / \(pages.count)")
                Button {
                    grid.toggle()
                } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.3x3")
                        .font(GlassTheme.labelFont).iconControlFrame(size: 26)
                }
                .buttonStyle(InteractionButtonStyle())
                .help(grid ? "列表显示" : "宫格显示")
            }

            if grid {
                EpisodeScroll(
                    ids: pages.map { String($0.cid) }, current: model.pageID.map(String.init) ?? "",
                    maxHeight: 216
                ) { _ in
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                        spacing: 6
                    ) {
                        ForEach(pages) { page in
                            let current = page.cid == model.pageID
                            Button {
                                model.selectPage(page.cid)
                            } label: {
                                Text("\(page.number)")
                                    .font(GlassTheme.labelFont.weight(current ? .bold : .medium))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .background {
                                        RoundedRectangle(cornerRadius: GlassTheme.rowRadius).fill(
                                            current ? GlassTheme.raisedFill : .white.opacity(0.05))
                                    }
                                    .overlay(alignment: .bottom) {
                                        if current {
                                            Capsule().fill(GlassTheme.accent)
                                                .frame(width: 14, height: 3).padding(.bottom, 6)
                                        }
                                    }
                            }
                            .buttonStyle(InteractionButtonStyle(kind: .row))
                            .help(page.title)
                            .id(String(page.cid))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                EpisodeScroll(
                    ids: pages.map { String($0.cid) }, current: model.pageID.map(String.init) ?? "",
                    maxHeight: 216
                ) { _ in
                    ForEach(pages) { page in
                        EpisodeRow(
                            title: page.title.isEmpty ? "P\(page.number)" : page.title,
                            duration: page.duration, current: page.cid == model.pageID
                        ) { model.selectPage(page.cid) }
                        .id(String(page.cid))
                    }
                }
            }
        }
    }
}

/// A list capped at a height that scrolls the current item into view when it changes.
private struct EpisodeScroll<Content: View>: View {
    let ids: [String]
    let current: String
    let maxHeight: CGFloat
    @ViewBuilder var content: (ScrollViewProxy) -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) { content(proxy) }
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        height = $0
                    }
            }
            .frame(height: min(maxHeight, max(height, 40)))
            // Rows bleed into the margin so their text lines up with the group header.
            .padding(.horizontal, -10)
            .scrollIndicators(height > maxHeight ? .automatic : .hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, value in
                withAnimation(Motion.standard) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }
}

// MARK: - Related videos

/// Related videos continue below the details with full-width rows, as in the official client.
struct RelatedVideoRow: View {
    let video: Video
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                ThumbnailView(url: video.cover, pixels: 340) { Color.primary.opacity(0.06) }
                    .frame(width: 132, height: 74).clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = video.duration, duration > 0 {
                            Text(timestamp(duration))
                                .font(GlassTheme.captionFont.weight(.medium)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(
                                    .black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: GlassTheme.badgeRadius)
                                )
                                .padding(4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(GlassTheme.labelFont.weight(.medium)).lineSpacing(2)
                        .lineLimit(2).frame(height: 40, alignment: .topLeading)
                    Label(video.author, systemImage: "person.crop.square").labelStyle(
                        StatLabelStyle()
                    )
                    .lineLimit(1)
                    HStack(spacing: 8) {
                        if let views = video.viewCount {
                            Label(DisplayFormat.count(views), systemImage: "play.rectangle")
                        }
                        if let danmaku = video.danmakuCount {
                            Label(DisplayFormat.count(danmaku), systemImage: "text.bubble")
                        }
                    }
                    .labelStyle(StatLabelStyle())
                }
                .font(GlassTheme.captionFont).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .padding(.horizontal, 12)
        .help("⌘-点击在后台标签打开")
    }
}

// MARK: - Loading

private struct IntroSkeleton: View {
    private let fill = Color.primary.opacity(0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(fill).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(fill).frame(width: 110, height: 13)
                    Capsule().fill(fill).frame(width: 150, height: 10)
                }
            }
            Capsule().fill(fill).frame(height: 15)
            Capsule().fill(fill).frame(height: 15).padding(.trailing, 90)
            Capsule().fill(fill).frame(width: 200, height: 10)
            RoundedRectangle(cornerRadius: GlassTheme.rowRadius).fill(fill).frame(height: 58)
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(fill).frame(width: 141, height: 79)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(fill).frame(height: 13)
                        Capsule().fill(fill).frame(height: 10).padding(.trailing, 50)
                    }
                }
            }
        }
        .shimmering()
        .accessibilityLabel("正在加载视频信息")
    }
}
