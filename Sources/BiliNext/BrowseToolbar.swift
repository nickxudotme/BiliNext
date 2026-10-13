import SwiftUI

/// The browse card's toolbar: section tabs or the page title, then search. It belongs to the
/// card rather than each page instance, so the selection indicator slides between sections.
struct BrowseToolbar: View {
    @ObservedObject var model: AppModel
    static let height: CGFloat = 76

    private static let homeSections = [
        ("推荐", "推荐"), ("热门", "热门"), ("排行榜", "排行榜"), ("番剧", "番剧影视"),
    ]
    private static let dynamicSections = [("视频", "视频"), ("全部", "全部动态")]

    var body: some View {
        HStack(spacing: 14) {
            switch model.menu {
            case .home:
                SectionTabs(items: Self.homeSections, selection: model.homeSection) {
                    model.selectBrowseSection(destination: .home, section: $0)
                }
            case .dynamic:
                SectionTabs(items: Self.dynamicSections, selection: model.dynamicMode) {
                    model.selectBrowseSection(destination: .dynamic, section: $0)
                }
            case .favorites, .search, .history, .watchLater:
                Text(title).font(GlassTheme.pageTitleFont).lineLimit(1)
            }
            if model.loadedBrowseInstance(for: model.menu)?.loading == true {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 12)
            if model.menu != .search {
                ToolbarSearchField { model.search($0) }
            }
        }
        .padding(.horizontal, GlassTheme.contentInset)
        .frame(height: Self.height)
    }

    private var title: String {
        if model.menu == .favorites,
            let page = model.loadedBrowseInstance(for: .favorites),
            let folder = page.folders.first(where: { $0.id == page.folderID })
        {
            return folder.title
        }
        return model.menu.title
    }
}

/// A sliding segmented control whose raised selection matches the card language.
struct SectionTabs: View {
    let items: [(id: String, title: String)]
    let selection: String
    let select: (String) -> Void
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
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
        .background(.primary.opacity(0.06), in: Capsule())
        .animation(Motion.emphasized(reduceMotion), value: selection)
        .accessibilityElement(children: .contain)
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

/// A resting capsule that widens into a field when clicked, then hands the keyword to the
/// search page. It only becomes a text field on demand, so it never takes launch focus.
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
        .padding(.horizontal, 12)
        .frame(width: editing ? 340 : 240, height: 34)
        .background {
            Capsule().fill(editing ? GlassTheme.raisedFill : .primary.opacity(0.06))
                .shadow(color: .black.opacity(editing ? 0.12 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            Capsule().strokeBorder(GlassTheme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1)
        }
        .contentShape(Capsule())
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
