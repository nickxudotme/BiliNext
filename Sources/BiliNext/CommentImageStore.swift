import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Comment pictures retain GIF bytes; video artwork continues to use static thumbnails.
enum CommentImageStore {
    final class Asset: @unchecked Sendable {
        let poster: CGImage
        let animation: Data?

        init(poster: CGImage, animation: Data?) {
            self.poster = poster
            self.animation = animation
        }

        /// Each view owns its frame cursor, including a thumbnail and its open viewer.
        @MainActor func makeImage() -> NSImage {
            if let animation, let image = NSImage(data: animation) { return image }
            return NSImage(cgImage: poster, size: .zero)
        }
    }

    private static let requests = Requests()

    static func image(url: URL, pixels: Int) async -> Asset? {
        await requests.image(url: url, pixels: pixels)
    }

    actor Requests {
        private let session: URLSession
        private let dataCache = NSCache<NSURL, NSData>()
        private let imageCache = NSCache<NSString, Asset>()
        private struct Pending {
            let task: Task<Data?, Never>
            var consumers: Set<UUID>
        }
        private var pending: [URL: Pending] = [:]

        init(session: URLSession = .shared) {
            self.session = session
            dataCache.totalCostLimit = 24 * 1024 * 1024
            imageCache.totalCostLimit = 48 * 1024 * 1024
        }

        func image(url: URL, pixels: Int) async -> Asset? {
            guard !Task.isCancelled else { return nil }
            let key = "\(url.absoluteString)#\(pixels)" as NSString
            if let image = imageCache.object(forKey: key) { return image }
            guard let data = await data(url: url), !Task.isCancelled else { return nil }
            let image = await Task.detached(priority: .utility) { () -> Asset? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let poster = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: max(1, pixels),
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary)
                else { return nil }
                let animated =
                    CGImageSourceGetType(source) == UTType.gif.identifier as CFString
                    && CGImageSourceGetCount(source) > 1
                return Asset(poster: poster, animation: animated ? data : nil)
            }.value
            guard !Task.isCancelled else { return nil }
            if let image {
                imageCache.setObject(
                    image, forKey: key,
                    cost: image.poster.bytesPerRow * image.poster.height
                        + (image.animation?.count ?? 0))
            }
            return image
        }

        /// Thumbnail and full-size requests share the download, including extensionless URLs.
        private func data(url: URL) async -> Data? {
            if let data = dataCache.object(forKey: url as NSURL) { return data as Data }
            let consumer = UUID()
            let task = pending[url]?.task ?? Task { await download(url: url) }
            var request = pending[url] ?? Pending(task: task, consumers: [])
            request.consumers.insert(consumer)
            pending[url] = request
            let data = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { await self.release(url, consumer: consumer) }
            }
            if let data, !Task.isCancelled {
                dataCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            }
            release(url, consumer: consumer)
            return Task.isCancelled ? nil : data
        }

        private func release(_ url: URL, consumer: UUID) {
            guard var request = pending[url], request.consumers.remove(consumer) != nil else {
                return
            }
            if request.consumers.isEmpty {
                pending[url] = nil
                request.task.cancel()
            } else {
                pending[url] = request
            }
        }

        private func download(url: URL) async -> Data? {
            do {
                let (data, response) = try await session.data(from: url)
                guard !Task.isCancelled,
                    (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) })
                        ?? true
                else { return nil }
                return data
            } catch { return nil }
        }
    }
}
