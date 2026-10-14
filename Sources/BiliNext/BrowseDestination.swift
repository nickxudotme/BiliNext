/// Sidebar browse pages. Raw values are the visible titles and also prefix navigation routes
/// and list cache keys, so they must stay stable.
enum BrowseDestination: String, CaseIterable, Sendable {
    case home = "首页"
    case search = "搜索"
    case dynamic = "动态"
    case favorites = "收藏"
    case history = "历史"
    case watchLater = "稍后再看"

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .dynamic: "rectangle.stack"
        case .favorites: "star"
        case .history: "clock.arrow.circlepath"
        case .watchLater: "clock"
        }
    }

    /// Account pages show a login prompt instead of loading anonymously.
    var requiresLogin: Bool {
        switch self {
        case .dynamic, .favorites, .history, .watchLater: true
        case .home, .search: false
        }
    }

    /// Pages listed in the sidebar. Search is reached from the toolbar's search field and ⌘L.
    static let sidebarItems = allCases.filter { $0 != .search }

    /// Favorite folders are listed under their sidebar row; home sections and dynamic modes
    /// live in the browse toolbar instead.
    var hasSidebarChildren: Bool { self == .favorites }
}
