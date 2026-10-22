import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var model: AppModel
    let keyword: String
    var isActive: Bool
    @State private var draft = ""
    private static let orders = [
        ("totalrank", "综合"), ("click", "最多播放"), ("pubdate", "最新发布"), ("stow", "最多收藏"),
    ]

    var body: some View {
        BrowseView(model: model, isActive: isActive, topInset: BrowseToolbar.height)
            .overlay(alignment: .top) {
                HStack(spacing: 16) {
                    Label("搜索结果", systemImage: "magnifyingglass")
                        .font(GlassTheme.sectionTitleFont)
                    TextField("搜索视频，或粘贴 BV 号 / 视频链接", text: $draft)
                        .textFieldStyle(.plain).font(GlassTheme.labelFont)
                        .padding(.horizontal, 14).frame(maxWidth: 420).frame(height: 38)
                        .floatingGlass(in: Capsule())
                        .onSubmit {
                            let submitted = draft
                            draft = keyword
                            model.search(submitted)
                        }
                    Spacer(minLength: 0)
                    SortMenu(options: Self.orders, selection: model.searchOrder) {
                        model.searchOrder = $0
                        model.refresh()
                    }
                }
                .padding(.horizontal, GlassTheme.contentInset)
                .frame(height: BrowseToolbar.height)
                .background {
                    SoftScrollEdge().frame(height: BrowseToolbar.height + 24)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { draft = keyword }
    }
}
