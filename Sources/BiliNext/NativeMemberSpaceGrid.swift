import AppKit
import SwiftUI

/// One native scroll view owns the header, pinned navigation and recycled grid.
struct NativeMemberSpaceGrid: NSViewRepresentable {
    let model: AppModel
    let entries: [MemberSpaceGridEntry]
    let contextID: String
    let isActive: Bool
    let loading: Bool
    let hasMore: Bool
    let loadMore: () -> Void
    let header: AnyView
    let bar: (Bool) -> AnyView
    let leading: AnyView
    let footer: AnyView
    let card: (MemberSpaceGridEntry) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> VideoGridScrollView {
        let scroll = VideoGridScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let document = SpaceGridDocument()
        document.frame = scroll.contentView.bounds
        document.autoresizingMask = [.width]
        scroll.documentView = document
        context.coordinator.attach(scroll, document: document)
        return scroll
    }

    func updateNSView(_ scroll: VideoGridScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: VideoGridScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var value: NativeMemberSpaceGrid
        let interaction = VideoGridInteraction()
        weak var scroll: VideoGridScrollView?
        weak var document: SpaceGridDocument?
        private var observer: NSObjectProtocol?
        private let header = NSHostingView(rootView: AnyView(EmptyView()))
        private let leading = NSHostingView(rootView: AnyView(EmptyView()))
        private let footer = NSHostingView(rootView: AnyView(EmptyView()))
        private let bar = NSHostingView(rootView: AnyView(EmptyView()))
        private var heights: [CGFloat] = [440, 0, 0]
        private var cards: [Int: NSHostingView<AnyView>] = [:]
        private var pool: [NSHostingView<AnyView>] = []
        private var idle: DispatchWorkItem?
        private var layoutScheduled = false
        private var paginationScheduled = false
        private var pinned = false
        private var width: CGFloat = 0
        private var stopped = false
        private var savedOffsets: [String: NSPoint] = [:]
        private var pendingOffset: NSPoint?

        init(_ value: NativeMemberSpaceGrid) { self.value = value }

        func attach(_ scroll: VideoGridScrollView, document: SpaceGridDocument) {
            self.scroll = scroll
            self.document = document
            for host in [header, leading, footer, bar] {
                host.sizingOptions = []
                document.addSubview(host)
            }
            bar.wantsLayer = true
            bar.layer?.zPosition = 1
            document.resized = { [weak self] in self?.scheduleLayout() }
            scroll.didScroll = { [weak self] in self?.beginScrolling() }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
            update(value)
        }

        private var geometry: MemberSpaceGridLayout {
            MemberSpaceGridLayout(
                width: width, headerHeight: heights[0], leadingHeight: heights[1],
                footerHeight: heights[2], count: value.entries.count)
        }

        func update(_ next: NativeMemberSpaceGrid) {
            let activityChanged = value.isActive != next.isActive
            let replaced = value.contextID != next.contextID
            let appended =
                next.entries.count >= value.entries.count
                && Array(next.entries.prefix(value.entries.count)) == value.entries
            let cardsChanged = !appended || value.isActive != next.isActive
            if replaced, let scroll {
                savedOffsets[value.contextID] = scroll.contentView.bounds.origin
                pendingOffset = savedOffsets[next.contextID] ?? .zero
            }
            if replaced || cardsChanged { recycleAll() }
            value = next
            if !next.isActive, activityChanged {
                idle?.cancel()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped, !self.value.isActive else { return }
                    if self.interaction.scrolling { self.interaction.scrolling = false }
                    self.value.model.hoverPreview.stop()
                }
            }
            updateSections()
            layout()
        }

        private func updateSections() {
            guard let scroll else { return }
            width = max(1, scroll.contentView.bounds.width)
            let sections = [value.header, value.leading, value.footer]
            for (index, host) in [header, leading, footer].enumerated() {
                let inset = index == 0 ? 0 : GlassTheme.contentInset
                host.rootView = AnyView(
                    sections[index]
                        .frame(width: max(1, width - inset * 2), alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            [weak self] height in
                            guard let self, abs(heights[index] - height) > 0.5 else { return }
                            heights[index] = height
                            scheduleLayout()
                        })
            }
            bar.rootView = value.bar(pinned)
        }

        private func scheduleLayout() {
            guard !stopped, !layoutScheduled else { return }
            layoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !stopped else { return }
                layoutScheduled = false
                layout()
            }
        }

        private func layout() {
            guard !stopped, let scroll, let document else { return }
            let viewport = scroll.contentView.bounds
            if abs(width - viewport.width) > 0.5 { updateSections() }
            let geometry = geometry
            let size = NSSize(width: width, height: max(viewport.height, geometry.contentHeight))
            if document.frame.size != size { document.setFrameSize(size) }
            if let offset = pendingOffset, !(value.loading && value.entries.isEmpty) {
                pendingOffset = nil
                scroll.contentView.scroll(
                    to: NSPoint(
                        x: 0, y: min(max(0, offset.y), max(0, size.height - viewport.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
                scheduleLayout()
            }
            header.frame = NSRect(x: 0, y: 0, width: width, height: heights[0])
            leading.frame = NSRect(
                x: geometry.inset, y: heights[0] + BrowseToolbar.height,
                width: max(1, width - geometry.inset * 2), height: heights[1])
            footer.frame = NSRect(
                x: geometry.inset, y: geometry.footerTop,
                width: max(1, width - geometry.inset * 2), height: heights[2])
            let nextPinned = viewport.minY >= heights[0] - 1
            if pinned != nextPinned {
                pinned = nextPinned
                bar.rootView = value.bar(pinned)
            }
            bar.frame = NSRect(
                x: 0, y: max(heights[0], viewport.minY), width: width,
                height: BrowseToolbar.height)
            let visible = Set(geometry.visibleIndices(in: viewport))
            for index in Array(cards.keys) where !visible.contains(index) { recycle(index) }
            for index in visible.sorted() {
                let host: NSHostingView<AnyView>
                if let existing = cards[index] {
                    host = existing
                } else {
                    host = pool.popLast() ?? NSHostingView(rootView: AnyView(EmptyView()))
                    host.sizingOptions = []
                    host.rootView = AnyView(
                        SpaceGridCard(
                            content: value.card(value.entries[index]), interaction: interaction
                        )
                        .id(value.entries[index].id))
                    document.addSubview(host, positioned: .below, relativeTo: bar)
                    cards[index] = host
                }
                let frame = geometry.frame(at: index)
                if host.frame != frame { host.frame = frame }
            }
            if value.isActive, !value.loading, value.hasMore, !value.entries.isEmpty,
                viewport.maxY >= geometry.contentHeight - viewport.height
            {
                schedulePagination()
            }
        }

        private func schedulePagination() {
            guard !paginationScheduled else { return }
            paginationScheduled = true
            let context = value.contextID
            DispatchQueue.main.async { [weak self] in
                guard let self, !stopped else { return }
                paginationScheduled = false
                guard value.isActive, !value.loading, value.hasMore, value.contextID == context
                else { return }
                value.loadMore()
            }
        }

        private func beginScrolling() {
            guard value.isActive else { return }
            if !interaction.scrolling {
                interaction.scrolling = true
                value.model.hoverPreview.stop()
            }
            idle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.interaction.scrolling = false }
            idle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func recycle(_ index: Int) {
            guard let host = cards.removeValue(forKey: index) else { return }
            if value.entries.indices.contains(index), case .video(let video) = value.entries[index]
            {
                value.model.hoverPreview.stop(ifMatching: video.id)
            }
            host.removeFromSuperview()
            host.rootView = AnyView(EmptyView())
            if pool.count < 32 { pool.append(host) }
        }

        private func recycleAll() { for index in Array(cards.keys) { recycle(index) } }

        func stop() {
            stopped = true
            idle?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            scroll?.didScroll = nil
            document?.resized = nil
            recycleAll()
            pool.removeAll()
            value.model.hoverPreview.stop()
        }
    }
}

private struct SpaceGridCard: View {
    let content: AnyView
    @ObservedObject var interaction: VideoGridInteraction
    var body: some View {
        content.environment(\.cardGridScrolling, interaction.scrolling)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

final class SpaceGridDocument: NSView {
    var resized: (() -> Void)?
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.width != newSize.width
        super.setFrameSize(newSize)
        if changed { resized?() }
    }
}
