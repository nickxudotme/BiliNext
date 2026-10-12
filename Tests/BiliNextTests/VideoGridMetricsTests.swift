import Foundation
import Testing

@testable import BiliNext

@Test func nativeGridKeepsCardsInsideViewportAtColumnBoundaries() {
    let cases: [(CGFloat, Int)] = [
        (280, 1), (595, 1), (596, 2), (875, 2), (876, 3), (1000, 3), (1155, 3), (1156, 4),
        (1280, 4),
    ]
    for (viewport, columns) in cases {
        let size = VideoGridMetrics.itemSize(viewportWidth: viewport, history: false)
        let available = viewport - GlassTheme.contentInset * 2
        #expect(size.width * CGFloat(columns) + CGFloat(columns - 1) * 20 <= available)
        #expect(
            size.width * CGFloat(columns) + CGFloat(columns - 1) * 20 > available - CGFloat(columns)
        )
        #expect(columns == 1 || size.width >= 260)
        #expect(size.height >= size.width * 9 / 16 + 94)
    }
}

@Test func nativeGridReservesHistoryMetadataWithoutChangingColumns() {
    let plain = VideoGridMetrics.itemSize(viewportWidth: 1000, history: false)
    let history = VideoGridMetrics.itemSize(viewportWidth: 1000, history: true)
    #expect(plain.width == history.width)
    #expect(history.height - plain.height == 52)
}
