import AppKit
import SwiftUI

private struct CommentImagePlaybackKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var commentImagePlaybackActive: Bool {
        get { self[CommentImagePlaybackKey.self] }
        set { self[CommentImagePlaybackKey.self] = newValue }
    }
}

struct CommentImageView<Placeholder: View>: View {
    let url: URL
    let pixels: Int
    var contentMode: ContentMode = .fill
    var defersLoadingUntilVisible = false
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var asset: CommentImageStore.Asset?
    @State private var appeared = false
    @State private var visible = false
    @State private var loadedRequest: String?
    @Environment(\.commentImagePlaybackActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let asset {
                CommentNativeImage(
                    asset: asset, contentMode: contentMode,
                    animates: active && appeared && !reduceMotion)
            } else {
                placeholder()
            }
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .task(
            id: active && (!defersLoadingUntilVisible || visible)
                ? "\(url.absoluteString)#\(pixels)" : nil
        ) {
            guard active, !defersLoadingUntilVisible || visible else { return }
            let request = "\(url.absoluteString)#\(pixels)"
            guard loadedRequest != request || asset == nil else { return }
            asset = nil
            let image = await CommentImageStore.image(url: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            asset = image
            loadedRequest = request
        }
    }
}

struct CommentNativeImage: NSViewRepresentable {
    let asset: CommentImageStore.Asset
    let contentMode: ContentMode
    let animates: Bool

    func makeNSView(context: Context) -> CommentImageSurface { CommentImageSurface() }

    func updateNSView(_ view: CommentImageSurface, context: Context) {
        view.update(asset: asset, contentMode: contentMode, animates: animates)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: CommentImageSurface, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: CommentImageSurface, coordinator: ()) {
        view.stop()
    }
}

/// AppKit advances GIF frames without invalidating the SwiftUI comment tree each frame.
final class CommentImageSurface: NSView {
    let imageView = NSImageView()
    private var asset: CommentImageStore.Asset?
    private var contentMode: ContentMode = .fill
    private var wantsAnimation = false
    private var scrollObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.animates = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(asset: CommentImageStore.Asset, contentMode: ContentMode, animates: Bool) {
        if self.asset !== asset {
            imageView.animates = false
            self.asset = asset
            imageView.image = asset.makeImage()
        }
        self.contentMode = contentMode
        wantsAnimation = animates && asset.animation != nil
        needsLayout = true
        updateAnimation()
    }

    override func layout() {
        super.layout()
        if let asset {
            let width = CGFloat(asset.poster.width)
            let height = CGFloat(asset.poster.height)
            let scale =
                contentMode == .fill
                ? max(bounds.width / width, bounds.height / height)
                : min(bounds.width / width, bounds.height / height)
            let size = CGSize(width: width * scale, height: height * scale)
            imageView.frame = CGRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height)
        }
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimation() }
            }
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    private func updateAnimation() {
        let animate =
            wantsAnimation && window != nil && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty
        if imageView.animates != animate { imageView.animates = animate }
    }

    func stop() {
        wantsAnimation = false
        imageView.animates = false
        imageView.image = nil
        asset = nil
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
}
