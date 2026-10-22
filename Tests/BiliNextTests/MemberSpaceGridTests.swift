import AppKit
import BiliNextCore
import Combine
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Test func spaceGridKeepsOnlyViewportCardsForThousandsOfUploads() {
    let layout = MemberSpaceGridLayout(
        width: 1100, headerHeight: 440, leadingHeight: 160, footerHeight: 30, count: 10_000)
    let viewport = NSRect(x: 0, y: 12_000, width: 1100, height: 800)
    let visible = layout.visibleIndices(in: viewport)
    #expect(visible.count < 30)
    #expect(!visible.isEmpty && visible.lowerBound > 0)
    for index in 0..<10_000 where layout.frame(at: index).intersects(viewport) {
        #expect(visible.contains(index))
    }
    #expect(layout.visibleIndices(in: NSRect(x: 0, y: 0, width: 1100, height: 100)).isEmpty)
    #expect(layout.frame(at: 0).minY > layout.headerHeight + BrowseToolbar.height)
    #expect(layout.frame(at: 0).maxX <= 1100 - layout.inset)
}

@MainActor
@Test func spaceGridHandlesEmptyNarrowAndLastRowGeometry() {
    for width in [CGFloat(100), 360, 800, 1600] {
        let layout = MemberSpaceGridLayout(
            width: width, headerHeight: 400, leadingHeight: 0, footerHeight: 20, count: 7)
        #expect(layout.columns >= 1 && layout.cardSize.width > 0)
        let bottom = NSRect(x: 0, y: layout.footerTop - 100, width: width, height: 200)
        #expect(layout.visibleIndices(in: bottom).upperBound <= 7)
        #expect(layout.contentHeight > layout.frame(at: 6).maxY)
    }
    let empty = MemberSpaceGridLayout(
        width: 900, headerHeight: 400, leadingHeight: 0, footerHeight: 20, count: 0)
    #expect(empty.rows == 0 && empty.gridHeight == 0)
    #expect(empty.visibleIndices(in: NSRect(x: 0, y: 0, width: 900, height: 800)).isEmpty)
}

@MainActor
@Test func nativeSpaceGridRecyclesAndPreservesOffsetWhenAppending() async {
    let model = AppModel(api: BilibiliAPI(restoreSession: false))
    let entries = (0..<1000).map {
        MemberSpaceGridEntry.video(Video(bvid: "video-\($0)", title: "视频 \($0)"))
    }
    func value(_ items: [MemberSpaceGridEntry], active: Bool = true, context: String = "uploads")
        -> NativeMemberSpaceGrid
    {
        NativeMemberSpaceGrid(
            model: model, entries: items, contextID: context, isActive: active,
            loading: false, hasMore: false, loadMore: {}, header: AnyView(Text("UP 主")),
            bar: { _ in AnyView(Text("投稿 / 合集和系列")) }, leading: AnyView(EmptyView()),
            footer: AnyView(EmptyView()), card: { _ in AnyView(Text("卡片")) })
    }
    let scroll = VideoGridScrollView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
    let document = SpaceGridDocument(frame: scroll.contentView.bounds)
    scroll.documentView = document
    let coordinator = value(entries).makeCoordinator()
    coordinator.attach(scroll, document: document)
    defer { coordinator.stop() }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 12_000))
    coordinator.update(value(entries))
    #expect(document.subviews.count < 40)
    #expect(scroll.contentView.bounds.minY == 12_000)
    let more = entries + [.video(Video(bvid: "last", title: "新增投稿"))]
    coordinator.update(value(more))
    #expect(scroll.contentView.bounds.minY == 12_000)
    coordinator.update(value(more, active: false))
    coordinator.update(value(more))
    #expect(scroll.contentView.bounds.minY == 12_000)
    #expect(document.subviews.count < 40)
    scroll.didScroll?()
    #expect(coordinator.interaction.scrolling)
    var changes = 0
    let scrolling = coordinator.interaction.objectWillChange.sink { changes += 1 }
    let preview = model.hoverPreview.objectWillChange.sink { changes += 1 }
    coordinator.update(value(more, active: false))
    #expect(changes == 0)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!coordinator.interaction.scrolling)
    #expect(changes == 1)
    changes = 0
    for _ in 0..<10 { coordinator.update(value(more, active: false)) }
    #expect(changes == 0)
    withExtendedLifetime((scrolling, preview)) {}
    coordinator.update(value(more, context: "collections"))
    coordinator.update(value(more))
    #expect(scroll.contentView.bounds.minY == 12_000)
}
