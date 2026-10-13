import AppKit
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
