import ImageIO
import SwiftUI

/// Decode at the display's working size off the main thread and reuse decoded pixels.
enum ThumbnailStore {
    static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let requests = Requests(session: .shared, cache: cache)

    static func cached(url: URL, pixels: Int) -> CGImage? {
        cache.object(forKey: "\(url.absoluteString)#\(pixels)" as NSString)
    }

    static func image(url: URL, pixels: Int) async -> CGImage? {
        await requests.image(url: url, pixels: pixels)
    }

    /// Preloading and a visible image join the same request, including its decode.
    actor Requests {
        private let session: URLSession
        private let cache: NSCache<NSString, CGImage>
        private struct Pending {
            let task: Task<CGImage?, Never>
            var consumers: Set<UUID>
        }
        private var pending: [String: Pending] = [:]

        init(session: URLSession, cache: NSCache<NSString, CGImage>) {
            self.session = session
            self.cache = cache
        }

        func image(url: URL, pixels: Int) async -> CGImage? {
            guard !Task.isCancelled else { return nil }
            let key = "\(url.absoluteString)#\(pixels)"
            if let image = cache.object(forKey: key as NSString) { return image }
            let consumer = UUID()
            let task = pending[key]?.task ?? Task { await download(url: url, pixels: pixels) }
            var request = pending[key] ?? Pending(task: task, consumers: [])
            request.consumers.insert(consumer)
            pending[key] = request
            let image = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.release(key, consumer: consumer) }
            }
            if let image, !Task.isCancelled {
                cache.setObject(
                    image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
            }
            release(key, consumer: consumer)
            return Task.isCancelled ? nil : image
        }

        private func release(_ key: String, consumer: UUID) {
            guard var request = pending[key], request.consumers.remove(consumer) != nil else {
                return
            }
            if request.consumers.isEmpty {
                pending[key] = nil
                request.task.cancel()
            } else {
                pending[key] = request
            }
        }

        private func download(url: URL, pixels: Int) async -> CGImage? {
            do {
                let (data, response) = try await session.data(from: url)
                guard
                    (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) })
                        ?? true,
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
                return image
            } catch {}
            return nil
        }
    }
}

struct ThumbnailView<Placeholder: View>: View {
    let url: URL?
    let pixels: Int
    let preparedImage: CGImage?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        url: URL?, pixels: Int, preparedImage: CGImage? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.pixels = pixels
        self.preparedImage = preparedImage
        self.placeholder = placeholder
        _image = State(
            initialValue: preparedImage
                ?? url.flatMap { ThumbnailStore.cached(url: $0, pixels: pixels) }
        )
    }

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
            // Cached artwork appears at once; freshly downloaded artwork fades in.
            image = preparedImage ?? url.flatMap { ThumbnailStore.cached(url: $0, pixels: pixels) }
            guard let url, image == nil else { return }
            let result = await ThumbnailStore.image(url: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.standard(reduceMotion)) { image = result }
        }
    }
}
