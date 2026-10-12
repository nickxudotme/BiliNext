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
        case "首页": return model.homeSection == "番剧" ? "番剧影视" : model.homeSection
        case "动态": return model.dynamicMode == "全部" ? "全部动态" : "视频动态"
        case "收藏": return model.folders.first(where: { $0.id == model.folderID })?.title ?? "收藏"
        default: return model.menu
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                Text(pageTitle).font(.system(size: 26, weight: .bold)).lineLimit(1)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, GlassTheme.contentInset).padding(.top, 28).padding(.bottom, 20)
                .background(GlassTheme.canvas)
                .overlay(alignment: .bottom) { Divider().opacity(0.35).padding(.horizontal, GlassTheme.contentInset) }
            if model.menu == "搜索" {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索视频，或粘贴 BV 号 / 视频链接", text: $model.query)
                        .textFieldStyle(.plain).focused($searching).onSubmit { model.refresh() }
                    Picker("排序", selection: $model.searchOrder) {
                        Text("综合").tag("totalrank")
                        Text("最多播放").tag("click")
                        Text("最新发布").tag("pubdate")
                        Text("最多收藏").tag("stow")
                    }.frame(width: 110).onChange(of: model.searchOrder) { _, _ in model.refresh() }
                    Button("搜索") { model.refresh() }.buttonStyle(.glass)
                }.padding(12).chromeSurface(in: RoundedRectangle(cornerRadius: GlassTheme.panelRadius))
                .padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 20)
            }
            if ["收藏", "历史"].contains(model.menu) {
                HStack {
                    TextField(model.menu == "收藏" ? "搜索当前收藏夹" : "搜索观看历史", text: $model.libraryQuery)
                        .textFieldStyle(.roundedBorder).onSubmit { model.refresh() }
                    if model.menu == "收藏" {
                        Picker("排序", selection: $model.favoriteOrder) {
                            Text("最近收藏").tag("mtime")
                            Text("最近投稿").tag("pubtime")
                            Text("最多播放").tag("view")
                        }.frame(width: 130).onChange(of: model.favoriteOrder) { _, _ in
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
                }.padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 12)
            }
            if model.menu == "历史" {
                Text("来自 B 站的观看历史 · 点击从上次进度继续").font(.caption).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 12)
            }
            if model.menu == "稍后再看", let removed = model.removedLater {
                HStack {
                    Text("已移除「\(removed.title)」").lineLimit(1)
                    Spacer()
                    Button("撤销") { model.changeWatchLater(removed) }.disabled(
                        model.libraryBusy.contains(removed.id))
                }
                .font(.callout).padding(.horizontal, GlassTheme.contentInset).padding(.bottom, 12)
            }
            if let error = model.browseError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    Button("重试") { model.refresh() }
                }
                .font(.callout).padding().background(.orange.opacity(0.08)).padding(.horizontal, GlassTheme.contentInset)
            }
            if model.menu == "首页" && model.homeSection == "番剧" {
                SeasonBrowser(model: model)
            } else if ["动态", "收藏", "历史", "稍后再看"].contains(model.menu) && model.profile == nil {
                ContentUnavailableView {
                    Label(
                        model.menu == "动态" ? "关注的更新，都在这里" : "登录后查看" + model.menu,
                        systemImage: "rectangle.stack")
                } description: {
                    Text("扫码登录，读取你在 B 站的内容。")
                } actions: {
                    Button("扫码登录") { model.loginPresented = true }.buttonStyle(.glassProminent)
                }

            } else if model.menu == "动态" && model.dynamicMode == "全部" {
                ActivityView(model: model)
            } else if model.videos.isEmpty && !model.loading && model.browseError == nil {
                ContentUnavailableView(
                    model.menu == "搜索" && model.query.isEmpty ? "找一部想看的视频" : "暂时没有视频",
                    systemImage: "play.rectangle",
                    description: Text(model.menu == "搜索" ? "支持关键词、BV 号和视频链接。" : "可以稍后刷新再看看。"))
            } else {
                NativeVideoGrid(model: model, isActive: isActive)
                    .id(model.menu)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: isActive) { _, active in
                if !active { searching = false }
            }
            .onChange(of: model.menu) { _, menu in if menu == "搜索" { searching = true } }
    }
}
