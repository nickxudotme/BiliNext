import AppKit
import BiliNextCore
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Suite(.serialized)
struct IntroScrollingTests {
    @Test func offscreenRecommendationsDoNotStartThumbnailRequests() async throws {
        _ = NSApplication.shared
        IntroThumbnailProtocol.reset()
        URLProtocol.registerClass(IntroThumbnailProtocol.self)
        defer { URLProtocol.unregisterClass(IntroThumbnailProtocol.self) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            sessionStore: SessionStore(directory: directory),
            api: BilibiliAPI(restoreSession: false))
        var detail = VideoDetail(
            video: Video(bvid: "intro-fixture", title: "简介滚动测试"), pages: [], description: "")
        detail.extras.related = (0..<100).map {
            Video(
                bvid: "related-\($0)", title: "推荐视频 \($0)",
                cover: URL(string: "https://intro-scroll.invalid/\($0)"))
        }
        model.detail = detail
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: [],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: VideoIntroPanel(model: model, isActive: false))
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        // Allow SwiftUI's layout and image tasks to run in an actual bounded viewport.
        try await Task.sleep(for: .milliseconds(600))
        let loaded = IntroThumbnailProtocol.count
        #expect(loaded > 0)
        #expect(loaded < 30, "Only visible/prefetched rows should load, got \(loaded) of 100")
        print("Intro viewport started \(loaded) of 100 thumbnail requests")

        let scroll = try #require(findScrollView(in: host))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(IntroThumbnailProtocol.count > loaded, "Scrolling must realize new recommendations")
        #expect(IntroThumbnailProtocol.count < 60)
    }

    @Test func eagerCommentPicturesLoadOnlyInsideTheViewport() async throws {
        _ = NSApplication.shared
        IntroThumbnailProtocol.reset()
        URLProtocol.registerClass(IntroThumbnailProtocol.self)
        defer { URLProtocol.unregisterClass(IntroThumbnailProtocol.self) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: [],
            backing: .buffered, defer: false)
        let host = NSHostingView(
            rootView: ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<100) { index in
                        CommentImageView(
                            url: URL(string: "https://intro-scroll.invalid/comment-\(index)")!,
                            pixels: 100, defersLoadingUntilVisible: true
                        ) { Color.gray }
                        .frame(width: 100, height: 100)
                    }
                }
            })
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let loaded = IntroThumbnailProtocol.count
        print("Comment viewport started \(loaded) of 100 picture requests")
        #expect(loaded > 0 && loaded < 20)
        let scroll = try #require(findScrollView(in: host))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 3000))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(IntroThumbnailProtocol.count > loaded)
        #expect(IntroThumbnailProtocol.count < 40)
    }

    @Test func standalonePictureViewerLoadsWithoutAScrollView() async throws {
        _ = NSApplication.shared
        IntroThumbnailProtocol.reset()
        URLProtocol.registerClass(IntroThumbnailProtocol.self)
        defer { URLProtocol.unregisterClass(IntroThumbnailProtocol.self) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: [],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: CommentImageView(
                url: URL(string: "https://intro-scroll.invalid/viewer")!, pixels: 2400,
                contentMode: .fit
            ) { Color.gray })
        defer { window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(IntroThumbnailProtocol.count == 1)
    }

    @Test func inactivePictureDefersItsRequestUntilActivated() async throws {
        _ = NSApplication.shared
        IntroThumbnailProtocol.reset()
        URLProtocol.registerClass(IntroThumbnailProtocol.self)
        defer { URLProtocol.unregisterClass(IntroThumbnailProtocol.self) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 600), styleMask: [],
            backing: .buffered, defer: false)
        func picture(active: Bool) -> some View {
            CommentImageView(
                url: URL(string: "https://intro-scroll.invalid/inactive")!, pixels: 100
            ) { Color.gray }
            .environment(\.commentImagePlaybackActive, active)
        }
        let host = NSHostingView(rootView: picture(active: false))
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(IntroThumbnailProtocol.count == 0)
        host.rootView = picture(active: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(IntroThumbnailProtocol.count == 1)
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }
}

private final class IntroThumbnailProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "intro-scroll.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}
