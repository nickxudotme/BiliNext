import BiliNextCore
import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var model: AppModel
    let keyword: String
    var isActive: Bool
    @State private var people = false
    private static let orders = [
        ("totalrank", "综合"), ("click", "最多播放"), ("pubdate", "最新发布"), ("stow", "最多收藏"),
        ("dm", "最多弹幕"),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            if people {
                PeopleSearchView(model: model, keyword: keyword)
                    .id("\(keyword):\(model.accountGeneration)").padding(.top, 108)
            } else {
                BrowseView(model: model, isActive: isActive, topInset: 108)
            }
            VStack(spacing: 10) {
                HStack {
                    Text("搜索结果").font(GlassTheme.sectionTitleFont)
                    Spacer()
                    SearchEntryField(
                        api: model.api, history: model.services.searchHistory, initial: keyword
                    ) { model.search($0) }
                }
                HStack(spacing: 16) {
                    Picker("搜索类型", selection: $people) {
                        Text("视频").tag(false)
                        Text("用户").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    if !people {
                        SortMenu(options: Self.orders, selection: model.searchOrder) {
                            model.searchOrder = $0
                            model.refresh()
                        }
                        Picker("时长", selection: $model.searchDuration) {
                            Text("全部时长").tag(0)
                            Text("10 分钟以下").tag(1)
                            Text("10–30 分钟").tag(2)
                            Text("30–60 分钟").tag(3)
                            Text("60 分钟以上").tag(4)
                        }.fixedSize()
                        Picker("发布", selection: $model.searchDays) {
                            Text("全部日期").tag(0)
                            Text("最近一天").tag(1)
                            Text("最近一周").tag(7)
                            Text("最近一月").tag(30)
                            Text("最近半年").tag(180)
                        }.fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, GlassTheme.contentInset).padding(.vertical, 12)
                .background { SoftScrollEdge().frame(height: 140) }.zIndex(2)
        }
        .onChange(of: model.searchDuration) { _, _ in model.refresh() }
        .onChange(of: model.searchDays) { _, _ in model.refresh() }
    }
}
