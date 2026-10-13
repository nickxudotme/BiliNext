import AppKit
import BiliNextCore
import SwiftUI
import Testing

@testable import BiliNext

/// Opt-in offscreen renders for reviewing shared states without a signed app:
/// `BILINEXT_RENDER_PREVIEW=1 swift test --filter VisualPreview` writes PNGs to the
/// directory in `BILINEXT_RENDER_DIR` (default /tmp). Glass does not render offscreen.
@MainActor
private func renderPreview(_ view: some View, name: String) throws {
    let directory = ProcessInfo.processInfo.environment["BILINEXT_RENDER_DIR"] ?? "/tmp"
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}

@MainActor
@Test func visualPreviewLoadingStates() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let view = VStack(spacing: 20) {
        ErrorBanner(message: "网络电波没能抵达，请稍后重试") {}.padding(.horizontal, 28)
        SkeletonVideoGrid().frame(height: 560)
    }
    .frame(width: 1180, height: 680).background(GlassTheme.canvas)
    .environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-loading-states")
}

@MainActor
@Test func visualPreviewPlayerControls() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.duration = 754
    model.time = 291
    model.quality = "1080P 高清"
    let samples: [Double] = (0..<50).map { index in
        let wave: Double = 35 * sin(Double(index) / 4)
        return 40 + wave + Double(index % 7) * 6
    }
    model.highEnergy = HighEnergyCurve(stepSeconds: 15, samples: samples)
    let view = CustomPlayerView(model: model, danmaku: model.danmaku)
        .frame(width: 960, height: 540)
    try renderPreview(view, name: "bilinext-player-controls")
    var scrubbing = false
    var scrubTime = 291.0
    let scrubber = PlaybackScrubber(
        time: 291, duration: 754, buffered: 380, activity: samples, showsActivity: true,
        scrubbing: Binding(get: { scrubbing }, set: { scrubbing = $0 }),
        scrubTime: Binding(get: { scrubTime }, set: { scrubTime = $0 }), seek: { _ in }
    )
    .padding(20).frame(width: 760).background(.black)
    try renderPreview(scrubber, name: "bilinext-scrubber")
}

@MainActor
@Test func visualPreviewVideoActions() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    let video = Video(bvid: "BV1111111111", title: "一", aid: 1)
    model.detail = VideoDetail(
        video: video, pages: [], description: "",
        stats: VideoStats(likes: 128_000, coins: 3456, favorites: 23_400, shares: 812))
    model.relation = VideoRelation(liked: true, coins: 1, favorited: false)
    let view = VideoActionBar(model: model, video: video)
        .padding(20).frame(width: 380).background(GlassTheme.canvas)
        .environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-video-actions")
}
