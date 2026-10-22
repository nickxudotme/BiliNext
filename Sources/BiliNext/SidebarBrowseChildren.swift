import SwiftUI

private let homeDestinations = ["推荐", "热门", "排行榜", "番剧"]
private let dynamicDestinations = ["视频", "全部"]

struct SidebarBrowseChildren: View {
    @ObservedObject var page: AppModel
    @ObservedObject var owner: AppModel
    let destination: BrowseDestination

    var body: some View {
        VStack(spacing: 2) {
            if destination == .favorites {
                ForEach(page.folders) { folder in
                    child(
                        folder.title, count: folder.count,
                        selected: (owner.loadedBrowseInstance(for: .favorites)?.folderID
                            ?? page.folderID) == folder.id
                    ) {
                        owner.selectFavoriteFolder(folder.id)
                    }
                }
                if page.folders.isEmpty {
                    if page.favoriteFoldersError != nil {
                        Button("收藏夹加载失败，重试") { owner.preloadFavoriteFolders() }
                            .buttonStyle(.plain)
                            .font(GlassTheme.captionFont).foregroundStyle(.secondary)
                            .padding(.leading, 34).padding(.vertical, 6)
                    } else {
                        Text(
                            page.profile == nil
                                ? "登录后查看收藏夹"
                                : page.favoriteFoldersLoading ? "加载收藏夹…" : "暂无收藏夹"
                        )
                        .font(GlassTheme.captionFont).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                        .padding(.vertical, 6)
                    }
                }
            } else {
                ForEach(destination == .home ? homeDestinations : dynamicDestinations, id: \.self) {
                    title in
                    child(
                        title == "番剧" ? "番剧影视" : title,
                        selected: (destination == .home ? page.homeSection : page.dynamicMode)
                            == title
                    ) {
                        owner.selectBrowseSection(destination: destination, section: title)
                    }
                }
            }
        }
    }

    private func child(
        _ title: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        SidebarChildRow(
            title: title, count: count,
            selected: selected && owner.menu == destination && owner.selected == nil, action: action
        )
    }
}

struct SidebarBrowsePlaceholder: View {
    let destination: BrowseDestination
    let select: (String) -> Void
    var body: some View {
        if destination == .favorites {
            Text("加载收藏夹…").font(GlassTheme.captionFont).foregroundStyle(.secondary)
        } else {
            ForEach(destination == .home ? homeDestinations : dynamicDestinations, id: \.self) {
                title in
                SidebarChildRow(title: title == "番剧" ? "番剧影视" : title, selected: false) {
                    select(title)
                }
            }
        }
    }
}

private struct SidebarChildRow: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text(count, format: .number).font(GlassTheme.captionFont).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(GlassTheme.labelFont.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.leading, 10).padding(.trailing, 10).frame(height: GlassTheme.childRowHeight)
            .contentShape(Rectangle())
            .background { NavigationSelection(selected: selected) }
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .padding(.leading, 24)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
