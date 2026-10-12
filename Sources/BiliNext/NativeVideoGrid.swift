import AppKit
import BiliNextCore
import SwiftUI

enum VideoGridMetrics {
    static let minimumCardWidth: CGFloat = 260
    static let columnSpacing: CGFloat = 20
    static let titleHeight: CGFloat = 48
    static let authorAvatarSize: CGFloat = 22
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

    func makeCoordinator() -> Coordinator { Coordinator(model: model, active: isActive) }

    func makeNSView(context: Context) -> VideoGridScrollView {
        let scroll = VideoGridScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        context.coordinator.observeBounds()
        return scroll
    }

    func updateNSView(_ scroll: VideoGridScrollView, context: Context) {
        context.coordinator.update(active: isActive)
    }

    static func dismantleNSView(_ view: VideoGridScrollView, coordinator: Coordinator) {
        coordinator.stop()
        view.didScroll = nil
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

        init(model: AppModel, active: Bool) {
            self.model = model
            self.active = active
        }

        func update(active: Bool) {
            let activityChanged = self.active != active
            self.active = active
            if !active {
                interaction.scrolling = false
                model.hoverPreview.stop()
            }
            guard let collection else { return }
            let old = videos
            videos = model.videos
            updateLayout()
            if old != videos {
                if videos.count > old.count && Array(videos.prefix(old.count)) == old {
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
            scheduleBottomCheck()
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
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleBottomCheck() }
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
            guard !checkScheduled else { return }
            checkScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                checkScheduled = false
                guard active, let collection, let scroll, !videos.isEmpty else { return }
                let height = collection.collectionViewLayout?.collectionViewContentSize.height ?? 0
                if scroll.contentView.bounds.maxY >= height - 160 { model.loadMoreIfNeeded() }
            }
        }

        func stop() {
            idleWork?.cancel()
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
            _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? VideoGridItem)?.stopPreview()
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
    private var host: NSHostingView<AnyView>?
    private var videoID: String?
    private weak var preview: HoverPreview?
    override func loadView() {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        self.host = host
        view = host
    }
    func configure(video: Video, model: AppModel, interaction: VideoGridInteraction, active: Bool) {
        _ = view
        videoID = video.id
        preview = model.hoverPreview
        host?.rootView = AnyView(
            HostedVideoCard(video: video, model: model, interaction: interaction, active: active))
    }
    func stopPreview() {
        if let videoID { preview?.stop(ifMatching: videoID) }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
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
    override func scrollWheel(with event: NSEvent) {
        didScroll?()
        super.scrollWheel(with: event)
    }
}
