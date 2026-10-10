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
    @State private var bottomVisible = false
    @FocusState private var searching: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.menu).font(.system(size: 26, weight: .semibold))
                if model.menu == "首页" {
                    Picker("内容", selection: $model.homeSection) {
                        Text("推荐").tag("推荐")
                        Text("热门").tag("热门")
                        Text("排行榜").tag("排行榜")
                        Text("番剧影视").tag("番剧")
                    }.pickerStyle(.segmented).frame(width: 300).onChange(of: model.homeSection) {
                        _, _ in model.refresh()
                    }
                }
                if model.menu == "动态" {
                    Picker("动态类型", selection: $model.dynamicMode) {
                        Text("视频").tag("视频")
                        Text("全部").tag("全部")
                    }.pickerStyle(.segmented).frame(width: 140).onChange(of: model.dynamicMode) {
                        _, _ in model.refresh()
                    }
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
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
                }.padding(12).background(
                    .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14)
                )
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            if model.menu == "收藏" && !model.folders.isEmpty {
                HStack {
                    Picker(
                        "收藏夹",
                        selection: Binding(get: { model.folderID }, set: { model.selectFolder($0) })
                    ) {
                        ForEach(model.folders) { folder in
                            Text("\(folder.title) · \(folder.count)").tag(folder.id)
                        }
                    }.frame(maxWidth: 360)
                    Spacer()
                }.padding(.horizontal, 28).padding(.bottom, 12)
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
                }.padding(.horizontal, 28).padding(.bottom, 12)
            }
            if model.menu == "历史" {
                Text("来自 B 站的观看历史 · 点击从上次进度继续").font(.caption).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if model.menu == "稍后再看", let removed = model.removedLater {
                HStack {
                    Text("已移除「\(removed.title)」").lineLimit(1)
                    Spacer()
                    Button("撤销") { model.changeWatchLater(removed) }.disabled(
                        model.libraryBusy.contains(removed.id))
                }
                .font(.callout).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if let error = model.browseError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    Button("重试") { model.refresh() }
                }
                .font(.callout).padding().background(.orange.opacity(0.08)).padding(.horizontal, 28)
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
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 20)],
                        alignment: .leading, spacing: 26
                    ) {
                        ForEach(model.videos) { video in
                            Button {
                                model.open(
                                    video, background: NSEvent.modifierFlags.contains(.command))
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Color.primary.opacity(0.04).aspectRatio(
                                        16 / 10, contentMode: .fit
                                    )
                                    .overlay {
                                        AsyncImage(url: video.cover) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Image(systemName: "play.rectangle").font(.largeTitle)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(video.title).font(.system(size: 14, weight: .medium))
                                        .lineLimit(2).frame(height: 38, alignment: .topLeading)
                                    HStack(spacing: 6) {
                                        AvatarView(url: video.avatar).frame(width: 16, height: 16)
                                        Text(video.author).lineLimit(1)
                                    }
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    if let viewed = video.viewedAt {
                                        HStack {
                                            Text(
                                                viewed,
                                                format: .dateTime.month().day().hour().minute())
                                            Spacer()
                                            if let progress = video.progress {
                                                Text(
                                                    progress < 0
                                                        ? "已看完" : "看到 " + timestamp(progress))
                                            }
                                        }.font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("在后台标签打开") { model.open(video, background: true) }
                                    Button(model.menu == "稍后再看" ? "从稍后再看移除" : "加入稍后再看") {
                                        model.changeWatchLater(video, remove: model.menu == "稍后再看")
                                    }.disabled(model.libraryBusy.contains(video.id))
                                }
                        }
                    }.padding(.horizontal, 28).padding(.vertical, 12)
                    if model.hasMore {
                        Button(model.loading ? "加载中…" : "加载更多") { model.refresh(more: true) }
                            .disabled(model.loading).padding(20)
                            .onScrollVisibilityChange { visible in
                                bottomVisible = visible
                                if visible { model.loadMoreIfNeeded() }
                            }
                    }
                }.id(model.menu)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: model.loading) { _, loading in
                if !loading && bottomVisible { model.loadMoreIfNeeded() }
            }
            .onChange(of: model.menu) { _, menu in if menu == "搜索" { searching = true } }
    }
}
