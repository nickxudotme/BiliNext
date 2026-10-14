import BiliNextCore
import ImageIO
import SwiftUI

/// Decoded preview sheets. Each 10×10 sheet arrives at 4800×2700; it is decoded at 3200 wide,
/// enough for a Retina 160×90 preview, and only about two sheets are kept.
@MainActor
enum VideoShotSheets {
    private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static var loading: [URL: Task<CGImage?, Never>] = [:]

    static func sheet(_ url: URL) async -> CGImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3200,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    static func frame(_ shots: VideoShots, at seconds: Double) async -> CGImage? {
        guard let frame = shots.frame(at: seconds),
            let sheet = await sheet(shots.sheets[frame.sheet])
        else { return nil }
        let width = sheet.width / shots.columns
        let height = sheet.height / shots.rows
        return sheet.cropping(
            to: CGRect(x: frame.column * width, y: frame.row * height, width: width, height: height)
        )
    }
}

/// The frame under the scrubber pointer, above its time.
struct VideoShotPreview: View {
    let shots: VideoShots
    let seconds: Double
    @State private var image: CGImage?

    private var frameKey: String {
        shots.frame(at: seconds).map { "\($0.sheet)-\($0.column)-\($0.row)" } ?? ""
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: frameKey) { image = await VideoShotSheets.frame(shots, at: seconds) ?? image }
    }
}
