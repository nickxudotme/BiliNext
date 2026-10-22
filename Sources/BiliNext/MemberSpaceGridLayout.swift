import AppKit

/// Fixed card geometry lets AppKit recycle cards without asking SwiftUI to measure every row.
struct MemberSpaceGridLayout {
    let width: CGFloat
    let headerHeight: CGFloat
    let leadingHeight: CGFloat
    let footerHeight: CGFloat
    let count: Int
    var inset: CGFloat { GlassTheme.contentInset }
    var cardSize: NSSize { VideoGridMetrics.itemSize(viewportWidth: width, history: false) }
    var columns: Int {
        max(
            1,
            Int(
                (width - inset * 2 + VideoGridMetrics.columnSpacing)
                    / (VideoGridMetrics.minimumCardWidth + VideoGridMetrics.columnSpacing)))
    }
    var gridTop: CGFloat { headerHeight + BrowseToolbar.height + leadingHeight + 8 }
    var rows: Int { (count + columns - 1) / columns }
    var gridHeight: CGFloat { CGFloat(rows) * (cardSize.height + 20) - (rows > 0 ? 20 : 0) }
    var footerTop: CGFloat { gridTop + gridHeight + 20 }
    var contentHeight: CGFloat { footerTop + footerHeight + 40 }

    func frame(at index: Int) -> NSRect {
        NSRect(
            x: inset + CGFloat(index % columns) * (cardSize.width + VideoGridMetrics.columnSpacing),
            y: gridTop + CGFloat(index / columns) * (cardSize.height + 20),
            width: cardSize.width, height: cardSize.height)
    }

    func visibleIndices(in viewport: NSRect) -> Range<Int> {
        guard count > 0, viewport.maxY >= gridTop, viewport.minY <= gridTop + gridHeight else {
            return 0..<0
        }
        let stride = cardSize.height + 20
        let first = max(0, Int(floor((viewport.minY - gridTop) / stride)) - 1)
        let last = min(rows, Int(ceil((viewport.maxY - gridTop) / stride)) + 1)
        return min(count, first * columns)..<min(count, max(first, last) * columns)
    }
}
