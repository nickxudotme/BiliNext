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
    /// Height of the floating toolbar; content starts below it but scrolls beneath it.
    var topInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var emptyState: (title: String, message: String, symbol: String) {
        switch model.menu {
        case .search where model.query.isEmpty:
            ("找一部想看的视频", "支持关键词、BV 号和视频链接。", "magnifyingglass")
        case .search: ("没有找到相关视频", "换个关键词，或者换一种排序试试。", "magnifyingglass")
        case .favorites: ("这个收藏夹还是空的", "在播放页点「收藏」，视频就会出现在这里。", "star")
        case .history: ("还没有观看记录", "看过的视频会出现在这里，点击即可从上次进度继续。", "clock.arrow.circlepath")
        case .watchLater: ("稍后再看是空的", "悬停视频卡片，点右上角的时钟就能加入。", "clock")
        case .dynamic: ("关注的 UP 主暂时没有新视频", "可以稍后刷新再看看。", "rectangle.stack")
        case .home: ("暂时没有视频", "可以稍后刷新再看看。", "play.rectangle")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.menu == .home && model.homeSection == "番剧" {
                SeasonBrowser(model: model).padding(.top, topInset)
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
                .padding(.top, topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if model.menu == .dynamic && model.dynamicMode == "全部" {
                ActivityView(model: model, topInset: topInset)
            } else if model.videos.isEmpty && model.loading && model.browseError == nil {
                SkeletonVideoGrid(history: model.menu == .history)
                    .padding(.top, topInset + 12)
                    .transition(.opacity)
            } else if model.videos.isEmpty && !model.loading && model.browseError == nil {
                ContentUnavailableView {
                    Label(emptyState.title, systemImage: emptyState.symbol)
                } description: {
                    Text(model.hasMore ? "这一批暂时没有视频，可以继续加载。" : emptyState.message)
                } actions: {
                    if model.hasMore {
                        Button("继续加载视频") { model.refresh(more: true) }.buttonStyle(.glass)
                    }
                }
                .padding(.top, topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeVideoGrid(model: model, isActive: isActive, topInset: topInset)
                    .id(model.menu)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(Motion.standard(reduceMotion), value: model.videos.isEmpty)
            // Notices float as glass just below the toolbar or above the bottom edge.
            .overlay(alignment: .top) {
                if let error = model.browseError {
                    ErrorBanner(message: error) { model.retryBrowse() }
                        .frame(maxWidth: 560)
                        .floatingGlass(in: RoundedRectangle(cornerRadius: GlassTheme.panelRadius))
                        .padding(.top, topInset + 4).padding(.horizontal, GlassTheme.contentInset)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if model.menu == .watchLater, let removed = model.removedLater {
                    HStack(spacing: 12) {
                        Text("已移除「\(removed.title)」").lineLimit(1).frame(maxWidth: 320)
                        Button("撤销") { model.changeWatchLater(removed) }
                            .buttonStyle(.glass)
                            .disabled(model.libraryBusy.contains(removed.id))
                    }
                    .font(GlassTheme.labelFont)
                    .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 6)
                    .floatingGlass(in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.standard(reduceMotion), value: model.browseError)
            .animation(Motion.standard(reduceMotion), value: model.removedLater?.id)
    }
}
