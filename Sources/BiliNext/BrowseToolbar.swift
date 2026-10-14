import BiliNextCore
import SwiftUI

/// The browse card's floating toolbar. Content scrolls beneath it; its controls are Liquid Glass
/// capsules over a soft, fading material edge. Each page's own controls (search, library
/// filter, followed lives) live here rather than in rows above the content.
struct BrowseToolbar: View {
    @ObservedObject var model: AppModel
    static let height: CGFloat = 68

    private static let homeSections = [
        ("推荐", "推荐"), ("热门", "热门"), ("排行榜", "排行榜"), ("番剧", "番剧影视"),
    ]
    private static let dynamicSections = [("视频", "视频"), ("全部", "全部动态")]

    private var page: AppModel? { model.loadedBrowseInstance(for: model.menu) }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                leading
                // A first load shows skeleton cards; the spinner is for refreshing existing content.
                if let page, page.loading, !page.videos.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 12)
                trailing
            }
        }
        .padding(.horizontal, GlassTheme.contentInset - 6)
        .frame(height: Self.height)
        .background(alignment: .top) {
            SoftScrollEdge().frame(height: Self.height + 30).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var leading: some View {
        switch model.menu {
        case .home:
            SectionTabs(items: Self.homeSections, selection: model.homeSection, glass: true) {
                model.selectBrowseSection(destination: .home, section: $0)
            }
        case .dynamic:
            SectionTabs(items: Self.dynamicSections, selection: model.dynamicMode, glass: true) {
                model.selectBrowseSection(destination: .dynamic, section: $0)
            }
        case .favorites, .search, .history, .watchLater:
            Text(title).font(GlassTheme.pageTitleFont).lineLimit(1).padding(.leading, 6)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.menu {
        case .search:
            if let page { SearchPageField(page: page) }
        case .favorites, .history:
            if let page { LibraryFilter(page: page) }
        case .dynamic:
            if let page, page.profile != nil {
                FollowedLivesButton(lives: page.followedLives, page: page)
            }
            ToolbarSearchField { model.search($0) }
        case .home, .watchLater:
            ToolbarSearchField { model.search($0) }
        }
    }

    private var title: String {
        if model.menu == .favorites, let page,
            let folder = page.folders.first(where: { $0.id == page.folderID })
        {
            return folder.title
        }
        return model.menu.title
    }
}

/// macOS 26's soft scroll edge: a material that fades out downwards, so floating controls
/// stay legible over whatever scrolls beneath them.
struct SoftScrollEdge: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let fade = LinearGradient(
            stops: [
                .init(color: .black, location: 0), .init(color: .black, location: 0.45),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        Group {
            if reduceTransparency {
                Rectangle().fill(GlassTheme.canvas)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .mask(fade)
    }
}

/// A sliding segmented control whose raised selection matches the card language. Floating
/// in a toolbar it sits on glass; inside a glass panel it uses a quiet fill instead.
struct SectionTabs: View {
    let items: [(id: String, title: String)]
    let selection: String
    var glass = false
    let select: (String) -> Void
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        items: [(id: String, title: String)], selection: String, glass: Bool = false,
        select: @escaping (String) -> Void
    ) {
        self.items = items
        self.selection = selection
        self.glass = glass
        self.select = select
    }

    var body: some View {
        let tabs = HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let selected = item.id == selection
                Button {
                    select(item.id)
                } label: {
                    Text(item.title)
                        .font(GlassTheme.bodyFont.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background {
                            if selected {
                                Capsule().fill(GlassTheme.raisedFill)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(SectionTabStyle())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .animation(Motion.emphasized(reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
        if glass {
            tabs.floatingGlass(in: Capsule())
        } else {
            tabs.background(.primary.opacity(0.06), in: Capsule())
        }
    }
}

/// Unselected tabs brighten on hover instead of drawing a second pill.
private struct SectionTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .brightness(hovered ? 0.08 : 0)
                .scaleEffect(!reduceMotion && configuration.isPressed ? 0.95 : 1)
                .animation(Motion.quick(reduceMotion), value: hovered)
                .animation(Motion.quick(reduceMotion), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

extension View {
    /// Floating toolbar glass, with an opaque fallback under Reduce Transparency.
    func floatingGlass<S: Shape>(in shape: S, focused: Bool = false) -> some View {
        modifier(FloatingGlass(shape: shape, focused: focused))
    }
}

private struct FloatingGlass<S: Shape>: ViewModifier {
    let shape: S
    let focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(GlassTheme.canvas, in: shape)
                    .overlay { shape.stroke(.primary.opacity(0.14), lineWidth: 1) }
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
            }
        }
        .overlay { shape.stroke(GlassTheme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1) }
    }
}

/// A resting glass capsule that widens into a field when clicked, then hands the keyword to
/// the search page. It only becomes a text field on demand, so it never takes launch focus.
struct ToolbarSearchField: View {
    let submit: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(GlassTheme.labelFont.weight(.medium))
                .foregroundStyle(.secondary)
            if editing {
                TextField("搜索视频、BV 号或链接", text: $text)
                    .textFieldStyle(.plain).font(GlassTheme.labelFont)
                    .focused($focused)
                    .onSubmit {
                        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !keyword.isEmpty else { return }
                        submit(keyword)
                        text = ""
                        focused = false
                    }
                    .onExitCommand { focused = false }
                    .onChange(of: focused) { _, focused in
                        if !focused && text.isEmpty { editing = false }
                    }
            } else {
                Text("搜索视频、BV 号或链接").font(GlassTheme.labelFont).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: editing ? 340 : 240, height: 38)
        .contentShape(Capsule())
        .floatingGlass(in: Capsule(), focused: focused)
        .onTapGesture {
            editing = true
            focused = true
        }
        .animation(Motion.standard(reduceMotion), value: editing)
        .animation(Motion.quick(reduceMotion), value: focused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("搜索")
        .accessibilityAddTraits(editing ? [] : [.isButton])
    }
}

/// The search page's own field and sort order, floating in the toolbar.
private struct SearchPageField: View {
    @ObservedObject var page: AppModel
    @FocusState private var focused: Bool

    private static let orders = [
        ("totalrank", "综合"), ("click", "最多播放"), ("pubdate", "最新发布"), ("stow", "最多收藏"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(GlassTheme.labelFont.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("搜索视频，或粘贴 BV 号 / 视频链接", text: $page.query)
                    .textFieldStyle(.plain).font(GlassTheme.labelFont)
                    .focused($focused).onSubmit { page.refresh() }
                if !page.query.isEmpty {
                    Button {
                        page.query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 14).frame(width: 380, height: 38)
            .floatingGlass(in: Capsule(), focused: focused)
            SortMenu(
                options: Self.orders, selection: page.searchOrder
            ) {
                page.searchOrder = $0
                page.refresh()
            }
        }
        .onAppear { focused = page.query.isEmpty }
    }
}

/// Searching inside a favorite folder or the watch history, with the folder's sort order.
private struct LibraryFilter: View {
    @ObservedObject var page: AppModel

    private static let orders = [("mtime", "最近收藏"), ("pubtime", "最近投稿"), ("view", "最多播放")]

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(GlassTheme.labelFont)
                    .foregroundStyle(.secondary)
                TextField(
                    page.menu == .favorites ? "搜索当前收藏夹" : "搜索观看历史", text: $page.libraryQuery
                )
                .textFieldStyle(.plain).font(GlassTheme.labelFont)
                .onSubmit { page.refresh() }
                if !page.libraryQuery.isEmpty {
                    Button {
                        page.libraryQuery = ""
                        page.refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除筛选")
                }
            }
            .padding(.horizontal, 14).frame(width: 260, height: 38)
            .floatingGlass(in: Capsule())
            if page.menu == .favorites {
                SortMenu(options: Self.orders, selection: page.favoriteOrder) {
                    page.favoriteOrder = $0
                    page.refresh()
                }
            }
        }
    }
}

private struct SortMenu: View {
    let options: [(String, String)]
    let selection: String
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button {
                    choose(option.0)
                } label: {
                    if option.0 == selection {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? "排序")
                Image(systemName: "chevron.down").font(GlassTheme.smallIconFont)
            }
            .font(GlassTheme.labelFont.weight(.medium))
            .padding(.horizontal, 14).frame(height: 38)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .floatingGlass(in: Capsule())
        .accessibilityLabel("排序")
    }
}

/// Followed lives on the dynamic page: a glass capsule of avatars that opens the list.
private struct FollowedLivesButton: View {
    @ObservedObject var lives: FollowedLives
    let page: AppModel
    @State private var presented = false

    var body: some View {
        if !lives.rooms.isEmpty {
            Button {
                presented.toggle()
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        ForEach(lives.rooms.prefix(3)) { room in
                            AvatarView(url: URL(string: room.avatar)).frame(width: 24, height: 24)
                                .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                        }
                    }
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("\(lives.rooms.count) 人在直播").font(GlassTheme.labelFont.weight(.medium))
                }
                .padding(.leading, 8).padding(.trailing, 14).frame(height: 38)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .floatingGlass(in: Capsule())
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lives.rooms) { room in
                            Button {
                                presented = false
                                page.openLive(room)
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(url: URL(string: room.avatar))
                                        .frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(room.author).font(
                                            GlassTheme.labelFont.weight(.semibold))
                                        Text(room.title).font(GlassTheme.metadataFont)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8).contentShape(Rectangle())
                            }
                            .buttonStyle(InteractionButtonStyle(kind: .row))
                        }
                    }
                    .padding(8)
                }
                .frame(width: 300).frame(maxHeight: 420)
            }
            .help("关注的直播")
        }
    }
}
