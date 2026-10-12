import Foundation
import Testing
@testable import BiliNext

@Test func nativeGridKeepsCardsInsideViewportAtColumnBoundaries() {
    for viewport in [CGFloat(280), 515, 516, 755, 756, 1335] {
        let size = VideoGridMetrics.itemSize(viewportWidth: viewport, history: false)
        let available = viewport - GlassTheme.contentInset * 2
        let columns = max(1, Int((available + 20) / 240))
        #expect(size.width * CGFloat(columns) + CGFloat(columns - 1) * 20 <= available)
        #expect(size.height >= size.width * 9 / 16 + 82)
    }
}

@Test func nativeGridReservesHistoryMetadataWithoutChangingColumns() {
    let plain = VideoGridMetrics.itemSize(viewportWidth: 1000, history: false)
    let history = VideoGridMetrics.itemSize(viewportWidth: 1000, history: true)
    #expect(plain.width == history.width)
    #expect(history.height - plain.height == 29)
}
