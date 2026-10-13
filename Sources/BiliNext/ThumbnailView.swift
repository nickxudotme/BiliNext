import ImageIO
import SwiftUI

/// Decode at the display's working size off the main thread and reuse decoded pixels.
private enum ThumbnailStore {
    static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func image(url: URL, pixels: Int) async -> CGImage? {
        let key = "\(url.absoluteString)#\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                !Task.isCancelled
            else { return nil }
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    return nil
                }
                return CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            }.value
            if let image, !Task.isCancelled {
                cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                return image
            }
        } catch {}
        return nil
    }
}

struct ThumbnailView<Placeholder: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: CGImage?

    private var requestID: String { "\(url?.absoluteString ?? "")#\(pixels)" }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: requestID) {
            image = nil
            guard let url else { return }
            let result = await ThumbnailStore.image(url: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
