import AppKit
import BiliNextCore
import SwiftUI

enum VideoGridMetrics {
    static let minimumCardWidth: CGFloat = 260
    static let columnSpacing: CGFloat = 20
    static let titleHeight: CGFloat = 46
    static let authorAvatarSize: CGFloat = 20
    static let historyMetadataHeight: CGFloat = 36

    static func itemSize(viewportWidth: CGFloat, history: Bool) -> NSSize {
        let available = max(1, viewportWidth - GlassTheme.contentInset * 2)
        let columns = max(1, Int((available + columnSpacing) / (minimumCardWidth + columnSpacing)))
        let width = floor(
            max(1, (available - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)))
        // Match the SwiftUI card's title, author row, spacing, and bottom padding.
        let contentHeight = 10 + titleHeight + 8 + authorAvatarSize + 6
        let historyHeight = history ? 10 + historyMetadataHeight + 6 : 0
        return NSSize(width: width, height: ceil(width * 9 / 16 + contentHeight + historyHeight))
    }
}

/// AppKit owns scrolling and recycling; the existing SwiftUI card owns its appearance and actions.
struct NativeVideoGrid: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(model: model, active: isActive) }

    func makeNSView(context: Context) -> VideoGridScrollView {
        let scroll = VideoGridScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        let collection = VideoGridCollectionView()
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.delegate = context.coordinator
        collection.dataSource = context.coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = VideoGridMetrics.columnSpacing
        layout.minimumLineSpacing = 26
        layout.sectionInset = NSEdgeInsets(
            top: 12, left: GlassTheme.contentInset, bottom: 12, right: GlassTheme.contentInset)
        collection.collectionViewLayout = layout
        collection.register(VideoGridItem.self, forItemWithIdentifier: Coordinator.itemID)
        collection.register(
            VideoGridFooter.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
            withIdentifier: Coordinator.footerID)
        collection.frame = scroll.contentView.bounds
        collection.autoresizingMask = [.width]
        scroll.documentView = collection
        context.coordinator.collection = collection
        context.coordinator.scroll = scroll
        collection.didResize = { [weak coordinator = context.coordinator] in
            coordinator?.updateLayout()
        }
        scroll.didScroll = { [weak coordinator = context.coordinator] in
            coordinator?.beginScrolling()
        }
        scroll.canRefresh = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.active && !coordinator.model.loading
        }
        scroll.refreshRequested = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.active, !coordinator.model.loading else { return }
            coordinator.model.refresh()
        }
        context.coordinator.observeBounds()
        return scroll
    }

    func updateNSView(_ scroll: VideoGridScrollView, context: Context) {
        context.coordinator.update(active: isActive, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: VideoGridScrollView, coordinator: Coordinator) {
        coordinator.stop()
        view.didScroll = nil
        view.canRefresh = nil
        view.refreshRequested = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        static let itemID = NSUserInterfaceItemIdentifier("video-card")
        static let footerID = NSUserInterfaceItemIdentifier("video-footer")
        let model: AppModel
        let interaction = VideoGridInteraction()
        var active: Bool
        var videos: [Video] = []
        weak var collection: VideoGridCollectionView?
        weak var scroll: VideoGridScrollView?
        var boundsObserver: NSObjectProtocol?
        var idleWork: DispatchWorkItem?
        var checkScheduled = false
        var revealScheduled = false
        var revealState = VideoGridRevealState()
        var reduceMotion = false
        var lastLoading = false
        var observedViewport: NSRect?
        var prefetchGeneration = 0

        init(model: AppModel, active: Bool) {
            self.model = model
            self.active = active
        }

        func update(active: Bool, reduceMotion: Bool) {
            let activityChanged = self.active != active
            self.active = active
            if activityChanged {
                prefetchGeneration += 1
                checkScheduled = false
            }
            let finishedLoading = lastLoading && !model.loading
            lastLoading = model.loading
            let motionChanged = self.reduceMotion != reduceMotion
            self.reduceMotion = reduceMotion
            if !active || (motionChanged && reduceMotion) {
                cancelVisibleReveals()
            }
            if !active {
                interaction.scrolling = false
                model.hoverPreview.stop()
                scroll?.cancelPullRefresh()
            }
            guard let collection else { return }
            scroll?.updateRefreshState(loading: model.loading)
            let old = videos
            videos = model.videos
            let refreshed = revealState.begin(revision: model.browseRevision)
            let dataChanged = refreshed || old != videos
            updateLayout()
            if dataChanged {
                if !refreshed, videos.count > old.count && Array(videos.prefix(old.count)) == old {
                    collection.insertItems(
                        at: Set((old.count..<videos.count).map { IndexPath(item: $0, section: 0) }))
                } else {
                    collection.reloadData()
                    scroll?.contentView.scroll(to: .zero)
                }
            }
            if activityChanged {
                for case let item as VideoGridItem in collection.visibleItems() {
                    if let index = collection.indexPath(for: item)?.item,
                        videos.indices.contains(index)
                    {
                        item.configure(
                            video: videos[index], model: model, interaction: interaction,
                            active: active)
                    }
                }
            }
            for case let footer as VideoGridFooter in collection.visibleSupplementaryViews(
                ofKind: NSCollectionView.elementKindSectionFooter)
            {
                footer.configure(model: model)
            }
            scheduleRevealBatch()
            if dataChanged || (!activityChanged && finishedLoading) {
                scheduleBottomCheck()
            }
        }

        func updateLayout() {
            guard let collection, let scroll,
                let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout
            else { return }
            let size = VideoGridMetrics.itemSize(
                viewportWidth: scroll.contentView.bounds.width,
                history: videos.contains { $0.viewedAt != nil })
            let footerSize = NSSize(width: size.width, height: model.hasMore ? 56 : 0)
            if layout.itemSize != size || layout.footerReferenceSize != footerSize {
                layout.itemSize = size
                layout.footerReferenceSize = footerSize
                layout.invalidateLayout()
            }
        }

        func observeBounds() {
            guard let scroll else { return }
            observedViewport = scroll.contentView.bounds
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll = self.scroll else { return }
                    let viewport = scroll.contentView.bounds
                    let previous = self.observedViewport
                    self.observedViewport = viewport
                    scroll.validatePullPosition()
                    self.scheduleRevealBatch()
                    // Layout and tab activation are not a request to fetch another page.
                    if let previous, previous.size == viewport.size,
                        previous.minY != viewport.minY
                    {
                        self.scheduleBottomCheck()
                    }
                }
            }
        }

        func scheduleRevealBatch() {
            guard active, !revealScheduled else { return }
            revealScheduled = true
            // Collect willDisplay callbacks from one layout pass into a single visible batch.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                revealScheduled = false
                guard active, let collection else { return }
                let visible = collection.visibleItems().compactMap {
                    candidate -> (Int, VideoGridItem)? in
                    guard let item = candidate as? VideoGridItem,
                        let index = collection.indexPath(for: item)?.item,
                        self.videos.indices.contains(index),
                        item.view.frame.intersects(collection.visibleRect)
                    else { return nil }
                    return (index, item)
                }.sorted { $0.0 < $1.0 }
                let claimed = Set(revealState.claim(visible.map { self.videos[$0.0].id }))
                let batch = visible.filter { claimed.contains(self.videos[$0.0].id) }
                let now = CACurrentMediaTime()
                for (position, entry) in batch.enumerated() {
                    entry.1.reveal(
                        at: now,
                        delay: VideoGridRevealState.delay(at: position, count: batch.count),
                        reduceMotion: reduceMotion)
                }
            }
        }

        func cancelVisibleReveals() {
            guard let collection else { return }
            for case let item as VideoGridItem in collection.visibleItems() {
                item.cancelReveal()
            }
        }

        func beginScrolling() {
            guard active else { return }
            if !interaction.scrolling {
                interaction.scrolling = true
                model.hoverPreview.stop()
            }
            idleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.interaction.scrolling = false }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func scheduleBottomCheck() {
            guard active, !checkScheduled else { return }
            checkScheduled = true
            let generation = prefetchGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == prefetchGeneration else { return }
                checkScheduled = false
                guard active, !model.loading, let collection, let scroll,
                    !scroll.isPullingToRefresh, !videos.isEmpty
                else { return }
                let height = collection.collectionViewLayout?.collectionViewContentSize.height ?? 0
                let viewport = scroll.contentView.bounds
                if viewport.maxY >= height - viewport.height { model.loadMoreIfNeeded() }
            }
        }

        func stop() {
            active = false
            prefetchGeneration += 1
            checkScheduled = false
            idleWork?.cancel()
            cancelVisibleReveals()
            scroll?.cancelPullRefresh()
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            model.hoverPreview.stop()
        }

        func collectionView(
            _ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>
        ) -> Set<IndexPath> {
            // SwiftUI buttons handle activation; avoid adding a second selection style.
            []
        }
        func collectionView(
            _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            scheduleRevealBatch()
        }
        func collectionView(
            _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? VideoGridItem)?.stopPreview()
            (item as? VideoGridItem)?.cancelReveal()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
            -> Int
        { videos.count }
        func collectionView(
            _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item =
                collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
                as! VideoGridItem
            item.configure(
                video: videos[indexPath.item], model: model, interaction: interaction,
                active: active)
            return item
        }
        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let footer =
                collectionView.makeSupplementaryView(
                    ofKind: kind, withIdentifier: Self.footerID, for: indexPath) as! VideoGridFooter
            footer.configure(model: model)
            return footer
        }
    }
}

@MainActor final class VideoGridInteraction: ObservableObject {
    @Published var scrolling = false
}

private struct HostedVideoCard: View {
    let video: Video
    let model: AppModel
    @ObservedObject var interaction: VideoGridInteraction
    let active: Bool
    var body: some View {
        VideoCardView(video: video, model: model, preview: model.hoverPreview, isActive: active)
            .environment(\.cardGridScrolling, interaction.scrolling)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(video.id)
    }
}

final class VideoGridItem: NSCollectionViewItem {
    static let revealAnimationKey = "BiliNext.cardReveal"
    private var host: NSHostingView<AnyView>?
    private var videoID: String?
    private weak var preview: HoverPreview?
    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        self.host = host
        // SwiftUI owns the hosting layer; a separate AppKit layer keeps reveals intact.
        view = container
    }
    func configure(video: Video, model: AppModel, interaction: VideoGridInteraction, active: Bool) {
        _ = view
        cancelReveal()
        videoID = video.id
        preview = model.hoverPreview
        host?.rootView = AnyView(
            HostedVideoCard(video: video, model: model, interaction: interaction, active: active))
    }
    func stopPreview() {
        if let videoID { preview?.stop(ifMatching: videoID) }
    }
    func reveal(at time: CFTimeInterval, delay: TimeInterval, reduceMotion: Bool) {
        cancelReveal()
        guard !reduceMotion, let layer = view.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.28
        let offset = CABasicAnimation(keyPath: "transform.translation.y")
        offset.fromValue = 6
        offset.toValue = 0
        offset.duration = 0.28
        let group = CAAnimationGroup()
        group.animations = [opacity, offset]
        group.duration = 0.28
        group.beginTime = layer.convertTime(time, from: nil) + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .backwards
        // Animate presentation only; the view's frame and final hit target stay unchanged.
        layer.add(group, forKey: Self.revealAnimationKey)
    }
    func cancelReveal() {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.revealAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelReveal()
        stopPreview()
        host?.rootView = AnyView(EmptyView())
        videoID = nil
    }
}

final class VideoGridFooter: NSView, NSCollectionViewElement {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(model: AppModel) {
        host.frame = bounds
        host.rootView = AnyView(
            Button(model.loading ? "加载中…" : "加载更多") { model.refresh(more: true) }
                .font(GlassTheme.labelFont).controlSize(.large)
                .disabled(model.loading).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}

final class VideoGridCollectionView: NSCollectionView {
    var didResize: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size.width != newSize.width
        super.setFrameSize(newSize)
        if changed { didResize?() }
    }
}

final class VideoGridScrollView: NSScrollView {
    var didScroll: (() -> Void)?
    var canRefresh: (() -> Bool)?
    var refreshRequested: (() -> Void)?
    private var pullRefresh = VideoGridPullRefreshState()
    private var refreshing = false
    private let refreshIndicator = VideoGridRefreshIndicator()
    var isPullingToRefresh: Bool { pullRefresh.tracking || refreshing }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(refreshIndicator)
        refreshIndicator.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        refreshIndicator.frame = NSRect(
            x: bounds.midX - 70, y: isFlipped ? 12 : bounds.height - 44,
            width: 140, height: 32)
    }

    func updateRefreshState(loading: Bool) {
        if !loading { refreshing = false }
        if loading && pullRefresh.tracking { pullRefresh.cancel() }
        updateRefreshIndicator()
    }

    func cancelPullRefresh() {
        pullRefresh.cancel()
        refreshing = false
        updateRefreshIndicator()
    }

    func validatePullPosition() {
        guard pullRefresh.tracking else { return }
        if contentView.bounds.minY > 1 || canRefresh?() != true {
            pullRefresh.cancel()
        }
        updateRefreshIndicator()
    }

    private func updateRefreshIndicator() {
        refreshIndicator.isHidden = !refreshing && pullRefresh.distance <= 0
        refreshIndicator.update(refreshing: refreshing, armed: pullRefresh.armed)
    }

    override func scrollWheel(with event: NSEvent) {
        didScroll?()
        let preciseGesture = event.hasPreciseScrollingDeltas && event.momentumPhase.isEmpty
        if preciseGesture, event.phase.contains(.began) {
            pullRefresh.begin(
                atTop: contentView.bounds.minY <= 1,
                available: canRefresh?() == true)
        }
        super.scrollWheel(with: event)
        guard preciseGesture else { return }
        if event.phase.contains(.cancelled) {
            pullRefresh.cancel()
        } else if event.phase.contains(.ended) {
            if pullRefresh.end(available: canRefresh?() == true) {
                refreshing = true
                refreshRequested?()
            }
        } else if event.phase.contains(.began) || event.phase.contains(.changed) {
            // Track the user's pull directly; AppKit owns the rubber-band presentation.
            pullRefresh.drag(
                by: event.scrollingDeltaY, atTop: contentView.bounds.minY <= 1,
                available: canRefresh?() == true)
        }
        updateRefreshIndicator()
    }
}

private final class VideoGridRefreshIndicator: NSView {
    private let spinner = NSProgressIndicator()
    private let arrow = NSImageView()
    private let label = NSTextField(labelWithString: "下拉刷新")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        arrow.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        addSubview(spinner)
        addSubview(arrow)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        spinner.frame = NSRect(x: 12, y: 8, width: 16, height: 16)
        arrow.frame = spinner.frame
        label.frame = NSRect(x: 36, y: 7, width: 96, height: 18)
    }
    func update(refreshing: Bool, armed: Bool) {
        label.stringValue = refreshing ? "正在刷新…" : armed ? "松开刷新" : "下拉刷新"
        arrow.isHidden = refreshing
        arrow.image = NSImage(
            systemSymbolName: armed ? "arrow.up" : "arrow.down", accessibilityDescription: nil)
        if refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
