import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import BiliNext

@MainActor
@Suite(.serialized)
struct HoverCoverPreloadTests {
    @Test func preparedHoverCoverIsDecodedAtTheDisplayedSizeAndReused() async throws {
        let fixture = try HoverArtworkFixture()
        defer { fixture.close() }
        let url = URL(string: "https://artwork.invalid/cover.png")!
        let preview = TabHoverPreview(loadCover: { await fixture.loader.image(url: $0, pixels: $1) }
        )
        await preview.preloadCovers(urls: [url])
        let prepared = try #require(preview.cover(for: url))
        #expect(prepared.width == 640 && prepared.height == 360)
        #expect(fixture.count == 1)
        let shown = await fixture.loader.image(url: url, pixels: TabHoverPreview.coverPixels)
        #expect(shown === prepared && fixture.count == 1)
        // Tab covers survive pressure from the ordinary scrolling-grid cache.
        fixture.cache.removeAllObjects()
        #expect(preview.cover(for: url) === prepared)
        // The first rendered frame must contain artwork without waiting for .task.
        let renderer = ImageRenderer(
            content: ThumbnailView(url: url, pixels: 640, preparedImage: preview.cover(for: url)) {
                Color.clear
            }.frame(width: 64, height: 36))
        let rendered = try #require(renderer.cgImage)
        let raster = try #require(
            CGContext(
                data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.draw(rendered, in: CGRect(x: 0, y: 0, width: 64, height: 36))
        let pixel = try #require(raster.data).assumingMemoryBound(to: UInt8.self)
        let center = (18 * 64 + 32) * 4
        #expect(pixel[center + 3] == 255 && pixel[center + 2] > pixel[center])
        await preview.preloadCovers(urls: [url])
        #expect(fixture.count == 1)
    }

    @Test func hoveringDuringPreloadJoinsTheSameDownloadAndDecode() async throws {
        let fixture = try HoverArtworkFixture()
        defer { fixture.close() }
        let url = URL(string: "https://artwork.invalid/pending.png")!
        async let first = fixture.loader.image(url: url, pixels: 640)
        async let second = fixture.loader.image(url: url, pixels: 640)
        let (prepared, shown) = await (first, second)
        #expect(prepared != nil && prepared === shown)
        #expect(fixture.count == 1)
    }

    @Test func startupArtworkIsBoundedDeduplicatedAndReleasedWithTabs() async throws {
        let fixture = try HoverArtworkFixture()
        defer { fixture.close() }
        let urls = (1...9).map { URL(string: "https://artwork.invalid/\($0).png")! }
        let preview = TabHoverPreview(loadCover: { await fixture.loader.image(url: $0, pixels: $1) }
        )
        await preview.preloadCovers(urls: urls + [urls[0]])
        #expect(fixture.count == 9 && fixture.peak <= 3)
        #expect(urls.allSatisfy { preview.cover(for: $0)?.width == 640 })
        let retained = preview.cover(for: urls[8])
        fixture.cache.removeAllObjects()
        await preview.preloadCovers(urls: [urls[8]])
        #expect(preview.cover(for: urls[0]) == nil)
        #expect(preview.cover(for: urls[8]) === retained && fixture.count == 9)
        await preview.preloadCovers(urls: [])
        #expect(preview.cover(for: urls[8]) == nil)
    }

    @Test func cancellationKeepsSharedConsumersAndStopsAnUnusedDownload() async throws {
        let fixture = try HoverArtworkFixture()
        defer { fixture.close() }
        let url = URL(string: "https://artwork.invalid/shared.png")!
        let first = Task { await fixture.loader.image(url: url, pixels: 640) }
        let second = Task { await fixture.loader.image(url: url, pixels: 640) }
        try await fixture.waitForRequests(1)
        first.cancel()
        let cancelled = await first.value
        let shown = await second.value
        #expect(cancelled == nil && shown != nil && fixture.count == 1)

        let unused = URL(string: "https://artwork.invalid/unused.png")!
        let abandoned = Task { await fixture.loader.image(url: unused, pixels: 640) }
        try await fixture.waitForRequests(2)
        abandoned.cancel()
        let discarded = await abandoned.value
        #expect(discarded == nil && fixture.stops > 0)
        let retried = await fixture.loader.image(url: unused, pixels: 640)
        #expect(retried != nil && fixture.count == 3)
    }
}

private final class HoverArtworkFixture: @unchecked Sendable {
    let cache = NSCache<NSString, CGImage>()
    let loader: ThumbnailStore.Requests
    private let session: URLSession
    private let lock = NSLock()
    private var total = 0
    private var active = 0
    private var maximum = 0
    private var stopped = 0
    var count: Int { lock.withLock { total } }
    var peak: Int { lock.withLock { maximum } }
    var stops: Int { lock.withLock { stopped } }

    init() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let encoded = data as Data
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoverArtworkProtocol.self]
        session = URLSession(configuration: config)
        loader = ThumbnailStore.Requests(session: session, cache: cache)
        HoverArtworkProtocol.respond = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock {
                self.total += 1
                self.active += 1
                self.maximum = max(self.maximum, self.active)
            }
            connection.cancelled = { [weak self] in self?.lock.withLock { self?.stopped += 1 } }
            // Keep downloads pending long enough for overlapping consumers to join.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.lock.withLock { self?.active -= 1 }
                guard !connection.stopped else { return }
                connection.client?.urlProtocol(
                    connection,
                    didReceive: HTTPURLResponse(
                        url: connection.request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "image/png"])!,
                    cacheStoragePolicy: .notAllowed)
                connection.client?.urlProtocol(connection, didLoad: encoded)
                connection.client?.urlProtocolDidFinishLoading(connection)
            }
        }
    }

    func close() {
        session.invalidateAndCancel()
        HoverArtworkProtocol.respond = nil
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<100 {
            if self.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(self.count >= count)
    }
}

private final class HoverArtworkProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((HoverArtworkProtocol) -> Void)?
    private let lock = NSLock()
    private var didStop = false
    var cancelled: (() -> Void)?
    var stopped: Bool { lock.withLock { didStop } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.respond?(self) }
    override func stopLoading() {
        lock.withLock { didStop = true }
        cancelled?()
    }
}
