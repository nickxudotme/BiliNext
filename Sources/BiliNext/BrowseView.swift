import BiliNextCore
import SwiftUI

struct AvatarView: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }.clipShape(Circle())
    }
}

struct BrowseView: View {
    @ObservedObject var model: AppModel
    var isActive = true
    @FocusState private var searching: Bool
    private var pageTitle: String {
        switch model.menu {
        case .home: return model.homeSection == "番剧" ? "番剧影视" : model.homeSection
        case .dynamic: return model.dynamicMode == "全部" ? "全部动态" : "视频动态"
        case .favorites:
            return model.folders.first(where: { $0.id == model.folderID })?.title ?? "收藏"
        case .search, .history, .watchLater: return model.menu.title
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                Text(pageTitle).font(GlassTheme.pageTitleFont).lineLimit(1)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, GlassTheme.contentInset).padding(.top, 28).padding(.bottom, 20)
                .background(GlassTheme.canvas)
                .overlay(alignment: .bottom) {
                    Divider().opacity(0.35).padding(.horizontal, GlassTheme.contentInset)
                }
            if model.menu == .search {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索视频，或粘贴 BV 号 / 视频链接", text: $model.query)
                        .textFieldStyle(.plain).focused($searching).onSubmit { model.refresh() }
                    Picker("排序", selection: $model.searchOrder) {
                        Text("综合").tag("totalrank")
                        Text("最多播放").tag("click")
                        Text("最新发布").tag("pubdate")
                        Text("最多收藏").tag("stow")
                    }.frame(width: 130).onChange(of: model.searchOrder) { _, _ in model.refresh() }
                    Button("搜索") { model.refresh() }.buttonStyle(.glass)
                }.font(GlassTheme.bodyFont).controlSize(.large)
                    .frame(minHeight: GlassTheme.controlHeight).padding(12).chromeSurface(
                        in: RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
                    )
                    .padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 20)
            }
            if model.menu == .dynamic, model.profile != nil {
                FollowedLiveView(lives: model.followedLives, model: model)
            }
            if [.favorites, .history].contains(model.menu) {
                HStack {
                    TextField(
                        model.menu == .favorites ? "搜索当前收藏夹" : "搜索观看历史", text: $model.libraryQuery
                    )
                    .textFieldStyle(.roundedBorder).onSubmit { model.refresh() }
                    if model.menu == .favorites {
                        Picker("排序", selection: $model.favoriteOrder) {
                            Text("最近收藏").tag("mtime")
                            Text("最近投稿").tag("pubtime")
                            Text("最多播放").tag("view")
                        }.frame(width: 150).onChange(of: model.favoriteOrder) { _, _ in
                            model.refresh()
                        }
                    }
                    Button("搜索") { model.refresh() }
                    if !model.libraryQuery.isEmpty {
                        Button("清除") {
                            model.libraryQuery = ""
                            model.refresh()
                        }
                    }
                }.font(GlassTheme.bodyFont).controlSize(.large)
                    .padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 16)
            }
            if model.menu == .history {
                Text("来自 B 站的观看历史 · 点击从上次进度继续").font(GlassTheme.metadataFont).foregroundStyle(
                    .secondary
                ).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 12)
            }
            if model.menu == .watchLater, let removed = model.removedLater {
                HStack {
                    Text("已移除「\(removed.title)」").lineLimit(1)
                    Spacer()
                    Button("撤销") { model.changeWatchLater(removed) }.disabled(
                        model.libraryBusy.contains(removed.id))
                }
                .font(GlassTheme.bodyFont).controlSize(.large).padding(
                    .horizontal, GlassTheme.contentInset
                ).padding(.bottom, 12)
            }
            if let error = model.browseError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    Button("重试") { model.retryBrowse() }
                }
                .font(GlassTheme.bodyFont).controlSize(.large).padding().background(
                    .orange.opacity(0.08)
                ).padding(.horizontal, GlassTheme.contentInset)
            }
            if model.menu == .home && model.homeSection == "番剧" {
                SeasonBrowser(model: model)
            } else if model.menu.requiresLogin && model.profile == nil {
                ContentUnavailableView {
                    Label(
                        model.menu == .dynamic ? "关注的更新，都在这里" : "登录后查看" + model.menu.title,
                        systemImage: "rectangle.stack")
                } description: {
                    Text("扫码登录，读取你在 B 站的内容。")
                } actions: {
                    Button("扫码登录") { model.loginPresented = true }.buttonStyle(.glassProminent)
                }

            } else if model.menu == .dynamic && model.dynamicMode == "全部" {
                ActivityView(model: model)
            } else if model.videos.isEmpty && !model.loading && model.browseError == nil {
                ContentUnavailableView {
                    Label(
                        model.menu == .search && model.query.isEmpty ? "找一部想看的视频" : "暂时没有视频",
                        systemImage: "play.rectangle")
                } description: {
                    Text(
                        model.hasMore
                            ? "这一批暂时没有视频，可以继续加载。"
                            : model.menu == .search ? "支持关键词、BV 号和视频链接。" : "可以稍后刷新再看看。")
                } actions: {
                    if model.hasMore {
                        Button("继续加载视频") { model.refresh(more: true) }.buttonStyle(.glass)
                    }
                }
            } else {
                NativeVideoGrid(model: model, isActive: isActive)
                    .id(model.menu)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: isActive) { _, active in
                if !active { searching = false }
            }
            .onChange(of: model.menu) { _, menu in if menu == .search { searching = true } }
    }
}
