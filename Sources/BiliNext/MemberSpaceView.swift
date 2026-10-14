import BiliNextCore
import SwiftUI

/// An uploader's space page, shown in its own sidebar tab. The header carries their banner
/// and identity; a floating glass bar switches between 投稿 and 合集和系列 and stays pinned
/// while the grid scrolls beneath it.
struct MemberSpaceView: View {
    @ObservedObject var space: MemberSpace
    /// The tab's page model, used to open videos and drive hover previews.
    @ObservedObject var model: AppModel
    var isActive = true
    @State private var headerHeight: CGFloat = 0
    @State private var barPinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gridColumns = [
        GridItem(
            .adaptive(minimum: VideoGridMetrics.minimumCardWidth),
            spacing: VideoGridMetrics.columnSpacing, alignment: .top)
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    SpaceHeader(space: space, model: model).id("top")
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            headerHeight = $0
                        }
                    Section {
                        content.padding(.horizontal, GlassTheme.contentInset)
                            .padding(.top, 8).padding(.bottom, 40)
                    } header: {
                        SpaceSectionBar(space: space, pinned: barPinned)
                    }
                }
            }
            // The bar's soft edge only appears once content scrolls beneath it.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                headerHeight > 0 && geometry.contentOffset.y >= headerHeight - 1
            } action: { _, pinned in
                barPinned = pinned
            }
            // Signing in from the prompt retries the order or search that needed it.
            .onChange(of: model.profile?.id) { _, id in
                if id != nil && space.uploadsNeedLogin { space.loadUploads() }
            }
            .onChange(of: space.openCollection?.id) { _, _ in
                withAnimation(Motion.standard(reduceMotion)) { proxy.scrollTo("top") }
            }
        }
        .background(GlassTheme.canvas)
    }

    @ViewBuilder private var content: some View {
        if let collection = space.openCollection {
            collectionDetail(collection)
        } else {
            switch space.section {
            case .uploads: uploads
            case .collections: collections
            }
        }
    }

    // MARK: 投稿

    @ViewBuilder private var uploads: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !space.searched.isEmpty {
                HStack(spacing: 8) {
                    Text("「\(space.searched)」的投稿").font(GlassTheme.sectionTitleFont)
                    Button("清除搜索") { space.clearSearch() }
                        .buttonStyle(.plain).font(GlassTheme.labelFont)
                        .foregroundStyle(.secondary)
                }
            } else if space.order == "pubdate", let pinned = space.pinned {
                PinnedVideoRow(video: pinned, model: model)
            }
            if space.uploadsNeedLogin {
                loginPrompt
            } else if let error = space.uploadsError, space.uploads.isEmpty {
                ErrorBanner(message: error) { space.loadUploads() }
            } else if space.uploads.isEmpty && space.uploadsLoading {
                SkeletonVideoGrid().padding(.horizontal, -GlassTheme.contentInset)
                    .frame(height: 640, alignment: .top)
            } else if space.uploads.isEmpty {
                ContentUnavailableView(
                    space.searched.isEmpty ? "还没有投稿" : "没有找到相关投稿",
                    systemImage: "play.rectangle"
                )
                .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                videoGrid(space.uploads, more: space.uploadsMore) {
                    space.loadUploads(more: true)
                }
                footer(loading: space.uploadsLoading, error: space.uploadsError) {
                    space.loadUploads(more: true)
                }
            }
        }
    }

    /// Signed out, play-count order and search are refused by Bilibili's risk control.
    private var loginPrompt: some View {
        ContentUnavailableView {
            Label("登录后可用", systemImage: "person.crop.circle")
        } description: {
            Text("按「最多播放」排序和搜索投稿需要登录。「最新发布」无需登录。")
        } actions: {
            Button("扫码登录") { model.loginPresented = true }.buttonStyle(.glass)
            Button("看最新发布") { space.showLatest() }.buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }

    // MARK: 合集和系列

    @ViewBuilder private var collections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = space.collectionsError, space.collections.isEmpty {
                ErrorBanner(message: error) { space.loadCollections() }
            } else if space.collections.isEmpty && space.collectionsLoaded {
                ContentUnavailableView("还没有合集和系列", systemImage: "square.stack")
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 24) {
                ForEach(space.collections) { collection in
                    CollectionCard(collection: collection) { space.open(collection) }
                        .onAppear {
                            if collection.id == space.collections.last?.id {
                                space.loadCollections(more: true)
                            }
                        }
                }
            }
            footer(loading: space.collectionsLoading, error: nil) {}
        }
        .onAppear { space.loadCollectionsIfNeeded() }
    }

    @ViewBuilder private func collectionDetail(_ collection: MemberCollection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                ThumbnailView(url: collection.cover, pixels: 480) { Color.primary.opacity(0.06) }
                    .frame(width: 176, height: 99)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.artworkRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(collection.title).font(GlassTheme.sheetTitleFont).lineLimit(2)
                    Text(Self.collectionSummary(collection))
                        .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let error = space.collectionError, space.collectionVideos.isEmpty {
                ErrorBanner(message: error) { space.loadCollectionVideos() }
            }
            if space.collectionVideos.isEmpty && space.collectionLoading {
                SkeletonVideoGrid().padding(.horizontal, -GlassTheme.contentInset)
                    .frame(height: 640, alignment: .top)
            } else {
                videoGrid(space.collectionVideos, more: space.collectionMore) {
                    space.loadCollectionVideos(more: true)
                }
                footer(loading: space.collectionLoading, error: nil) {}
            }
        }
    }

    static func collectionSummary(_ collection: MemberCollection) -> String {
        var parts = [collection.kind == .season ? "合集" : "系列", "\(collection.count) 个视频"]
        if let date = collection.updated { parts.append(DisplayFormat.relativeDate(date) + "更新") }
        return parts.joined(separator: " · ")
    }

    // MARK: Shared

    private func videoGrid(_ videos: [Video], more: Bool, loadMore: @escaping () -> Void)
        -> some View
    {
        LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 20) {
            ForEach(videos) { video in
                VideoCardView(
                    video: video, model: model, preview: model.hoverPreview, isActive: isActive,
                    showsAuthor: false
                )
                .onAppear { if more && video.id == videos.last?.id { loadMore() } }
            }
        }
    }

    @ViewBuilder private func footer(loading: Bool, error: String?, retry: @escaping () -> Void)
        -> some View
    {
        if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
        } else if let error {
            ErrorBanner(message: error, retry: retry)
        }
    }
}

// MARK: - Header

private struct SpaceHeader: View {
    @ObservedObject var space: MemberSpace
    @ObservedObject var model: AppModel
    @State private var signatureExpanded = false
    @State private var confirmingUnfollow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bannerHeight: CGFloat = 188
    static let avatarSize: CGFloat = 96

    private var card: MemberCard? { space.card }
    private var name: String { card?.name ?? model.tabs.first?.video.title ?? "UP 主" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    avatar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                                .textSelection(.enabled)
                            badges
                        }
                        if let card, !card.official.isEmpty {
                            Label(card.official, systemImage: "checkmark.seal.fill")
                                .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 4)
                    Spacer(minLength: 12)
                    actions.padding(.bottom, 6)
                }
                .padding(.top, -Self.avatarSize / 2)
                signature
                stats
                if let error = space.cardError {
                    ErrorBanner(message: error) { space.retryHeader() }.frame(maxWidth: 560)
                }
            }
            .padding(.horizontal, GlassTheme.contentInset)
            .padding(.bottom, 8)
        }
    }

    /// The uploader's banner, or a wash of their avatar when they have none, fading into the
    /// page so the header reads as one surface.
    private var banner: some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let url = card?.banner {
                ThumbnailView(url: url, pixels: 2000) { Color.clear }
            } else if let avatar = card?.avatar {
                ThumbnailView(url: avatar, pixels: 96) { Color.clear }
                    .scaleEffect(1.8).blur(radius: 60, opaque: true).saturation(1.4)
                    .opacity(0.6)
            }
        }
        .frame(height: Self.bannerHeight).frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [GlassTheme.canvas.opacity(0), GlassTheme.canvas],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 96)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: card?.banner)
        .accessibilityHidden(true)
    }

    private var avatar: some View {
        AvatarView(url: card?.avatar ?? model.tabs.first?.video.avatar)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .padding(4)
            .background(GlassTheme.canvas, in: Circle())
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .overlay(alignment: .bottomTrailing) {
                if let live = space.liveRoom, live.live {
                    Text("直播中").font(GlassTheme.captionFont.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .overlay { Capsule().strokeBorder(GlassTheme.canvas, lineWidth: 2) }
                        .offset(x: 4, y: -2)
                }
            }
    }

    @ViewBuilder private var badges: some View {
        if let card, card.level > 0 {
            Text("LV\(card.level)").font(GlassTheme.captionFont.weight(.bold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: Capsule())
        }
        if let card, !card.vipLabel.isEmpty {
            Text(card.vipLabel).font(GlassTheme.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: Capsule())
        }
    }

    @ViewBuilder private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if let live = space.liveRoom, live.live {
                    capsule {
                        model.openLive(
                            LiveRoom(
                                id: live.roomID, title: live.title, author: name,
                                avatar: card?.avatar?.absoluteString ?? ""))
                    } label: {
                        Label("看直播", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.red)
                    }
                    .help(live.title)
                }
                if let card, model.profile != nil, model.profile?.id != card.id {
                    capsule {
                        if card.following {
                            confirmingUnfollow = true
                        } else {
                            space.toggleFollow()
                        }
                    } label: {
                        // Pink marks only your own state: the uploader you already follow.
                        if card.following {
                            Label("已关注", systemImage: "checkmark")
                                .foregroundStyle(GlassTheme.accent)
                        } else {
                            Label("关注", systemImage: "plus")
                        }
                    }
                    .help(card.following ? "取消关注" : "关注 \(card.name)")
                    .disabled(space.followBusy)
                    .confirmationDialog(
                        "取消关注 \(card.name)？", isPresented: $confirmingUnfollow
                    ) {
                        Button("取消关注", role: .destructive) { space.toggleFollow() }
                    }
                }
                Menu {
                    Link("在浏览器中打开空间", destination: space.url)
                    Button("复制空间链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(space.url.absoluteString, forType: .string)
                    }
                    Button("复制 UID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(space.mid), forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(GlassTheme.labelFont.weight(.semibold))
                        .frame(width: 38, height: 34).contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .floatingGlass(in: Capsule())
                .accessibilityLabel("更多")
            }
        }
    }

    private func capsule<Label: View>(
        action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().font(GlassTheme.labelFont.weight(.medium))
                .padding(.horizontal, 16).frame(height: 34).contentShape(Capsule())
        }
        .buttonStyle(.plain).floatingGlass(in: Capsule())
    }

    @ViewBuilder private var signature: some View {
        let text = card?.signature ?? ""
        if !text.isEmpty {
            Text(text).font(GlassTheme.labelFont).foregroundStyle(.secondary)
                .lineSpacing(3).lineLimit(signatureExpanded ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .onTapGesture {
                    withAnimation(Motion.standard(reduceMotion)) { signatureExpanded.toggle() }
                }
        }
    }

    private var stats: some View {
        HStack(spacing: 32) {
            stat("粉丝", card?.followers)
            stat("关注", card?.followings)
            stat("获赞", card?.likes)
            stat("投稿", card?.videos)
        }
        .redacted(reason: card == nil ? .placeholder : [])
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(DisplayFormat.count) ?? "0000")
                .font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(title).font(GlassTheme.captionFont).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section bar

/// The floating glass bar pinned above the grid.
private struct SpaceSectionBar: View {
    @ObservedObject var space: MemberSpace
    var pinned = false
    @FocusState private var searching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                if space.openCollection != nil {
                    Button {
                        space.closeCollection()
                    } label: {
                        Label("合集和系列", systemImage: "chevron.left")
                            .font(GlassTheme.labelFont.weight(.medium))
                            .padding(.horizontal, 14).frame(height: 38)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).floatingGlass(in: Capsule())
                    .keyboardShortcut("[", modifiers: .command)
                } else {
                    SectionTabs(
                        items: MemberSpace.Section.allCases.map { ($0.rawValue, $0.rawValue) },
                        selection: space.section.rawValue, glass: true
                    ) { id in
                        if let section = MemberSpace.Section(rawValue: id) {
                            space.section = section
                        }
                    }
                }
                Spacer(minLength: 12)
                if space.openCollection == nil && space.section == .uploads {
                    search
                    SortMenu(options: MemberSpace.orders, selection: space.order) {
                        space.setOrder($0)
                    }
                }
            }
        }
        .padding(.horizontal, GlassTheme.contentInset - 6)
        .frame(height: BrowseToolbar.height)
        .background(alignment: .top) {
            SoftScrollEdge().frame(height: BrowseToolbar.height + 24).allowsHitTesting(false)
                .opacity(pinned ? 1 : 0)
                .animation(Motion.quick(reduceMotion), value: pinned)
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(GlassTheme.labelFont.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("搜索投稿视频", text: $space.keyword)
                .textFieldStyle(.plain).font(GlassTheme.labelFont)
                .focused($searching).onSubmit { space.search() }
            if !space.keyword.isEmpty {
                Button {
                    space.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14).frame(width: 240, height: 38)
        .floatingGlass(in: Capsule(), focused: searching)
    }
}

// MARK: - Cards

/// The pinned video, lifted above the grid as one wide row.
private struct PinnedVideoRow: View {
    let video: Video
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.open(video, background: NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(alignment: .top, spacing: 18) {
                ThumbnailView(url: video.cover, pixels: 720) { Color.primary.opacity(0.06) }
                    .frame(width: 300, height: 169)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.artworkRadius))
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = video.duration, duration > 0 {
                            Text(timestamp(duration)).font(GlassTheme.captionFont.weight(.medium))
                                .monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 10) {
                    Label("置顶视频", systemImage: "pin.fill")
                        .font(GlassTheme.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(video.title).font(.system(size: 18, weight: .semibold))
                        .lineSpacing(3).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 12) {
                        if let views = video.viewCount {
                            Label(DisplayFormat.count(views), systemImage: "play")
                        }
                        if let date = video.pubdate { Text(DisplayFormat.relativeDate(date)) }
                    }
                    .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(10).contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .padding(.horizontal, -10)
    }
}

/// A 合集 or 系列, drawn as a small stack of covers.
private struct CollectionCard: View {
    let collection: MemberCollection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    // Two receding sheets behind the cover read as a stack of videos.
                    RoundedRectangle(cornerRadius: GlassTheme.artworkRadius)
                        .fill(.primary.opacity(0.07)).padding(.horizontal, 22).offset(y: -10)
                    RoundedRectangle(cornerRadius: GlassTheme.artworkRadius)
                        .fill(.primary.opacity(0.13)).padding(.horizontal, 11).offset(y: -5)
                    Color.primary.opacity(0.06)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            ThumbnailView(url: collection.cover, pixels: 640) { Color.clear }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: GlassTheme.artworkRadius))
                        .overlay(alignment: .bottomTrailing) {
                            Label("\(collection.count)", systemImage: "square.stack")
                                .font(GlassTheme.captionFont.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(8)
                        }
                }
                .padding(.top, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(collection.title).font(GlassTheme.bodyFont.weight(.medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(height: VideoGridMetrics.titleHeight, alignment: .topLeading)
                    Text(MemberSpaceView.collectionSummary(collection))
                        .font(GlassTheme.metadataFont).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 2).padding(.bottom, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
    }
}
