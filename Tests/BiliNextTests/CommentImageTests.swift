import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import BiliNext

@MainActor
@Suite(.serialized)
struct CommentImageTests {
    @Test func commentImageKeepsGIFFrames() async throws {
        let data = try commentGIFFixture()
        let fixture = CommentImageFixture(data: data)
        defer { fixture.close() }
        // The CDN's path need not have a GIF extension.
        let url = URL(string: "https://pictures.invalid/animation")!
        let asset = try #require(await fixture.loader.image(url: url, pixels: 32))
        #expect(asset.poster.width == 32 && asset.poster.height == 16)
        #expect(asset.animation == data)
        let image = asset.makeImage()
        let decoded = try #require(image.representations.first as? NSBitmapImageRep)
        #expect((decoded.value(forProperty: .frameCount) as? NSNumber)?.intValue == 2)
        #expect((decoded.value(forProperty: .loopCount) as? NSNumber)?.intValue == 0)
        let duration = try #require(
            decoded.value(forProperty: .currentFrameDuration) as? NSNumber)
        #expect(abs(duration.doubleValue - 0.1) < 0.00001)
        // A second native view must not mutate the first view's animation cursor.
        let other = try #require(asset.makeImage().representations.first as? NSBitmapImageRep)
        decoded.setProperty(.currentFrame, withValue: 1)
        other.setProperty(.currentFrame, withValue: 0)
        #expect((decoded.value(forProperty: .currentFrame) as? NSNumber)?.intValue == 1)
        #expect((other.value(forProperty: .currentFrame) as? NSNumber)?.intValue == 0)
        let cached = await fixture.loader.image(url: url, pixels: 32)
        #expect(cached === asset && fixture.count == 1)
    }

    @Test func staticPicturesStillDecodeAtDisplaySize() async throws {
        let fixture = CommentImageFixture(data: try commentGIFFixture(type: .png))
        defer { fixture.close() }
        let asset = try #require(
            await fixture.loader.image(
                url: URL(string: "https://pictures.invalid/still")!, pixels: 32))
        #expect(asset.animation == nil)
        #expect(asset.poster.width == 32 && asset.poster.height == 16)
    }

    @Test func thumbnailAndViewerShareDownloadAndCancellation() async throws {
        let fixture = CommentImageFixture(data: try commentGIFFixture())
        defer { fixture.close() }
        let url = URL(string: "https://pictures.invalid/shared")!
        let thumbnail = Task { await fixture.loader.image(url: url, pixels: 32) }
        let viewer = Task { await fixture.loader.image(url: url, pixels: 2400) }
        try await fixture.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(10))
        thumbnail.cancel()
        let discarded = await thumbnail.value
        let full = await viewer.value
        #expect(discarded == nil && full?.animation != nil && fixture.count == 1)
        let small = await fixture.loader.image(url: url, pixels: 32)
        #expect(small?.poster.width == 32 && fixture.count == 1)

        let unused = URL(string: "https://pictures.invalid/unused")!
        let abandoned = Task { await fixture.loader.image(url: unused, pixels: 480) }
        try await fixture.waitForRequests(2)
        abandoned.cancel()
        #expect(await abandoned.value == nil)
        #expect(fixture.stops > 0)
        #expect(await fixture.loader.image(url: unused, pixels: 480) != nil)
        #expect(fixture.count == 3)
    }

    @Test func failedImagesCanRetry() async throws {
        let fixture = CommentImageFixture(data: try commentGIFFixture())
        defer { fixture.close() }
        fixture.status = 403
        let url = URL(string: "https://pictures.invalid/retry")!
        #expect(await fixture.loader.image(url: url, pixels: 480) == nil)
        fixture.status = 200
        #expect(await fixture.loader.image(url: url, pixels: 480)?.animation != nil)
        #expect(fixture.count == 2)
    }

    @Test func nativeImageRespectsVisibilitySizingAndViewOwnership() async throws {
        let fixture = CommentImageFixture(data: try commentGIFFixture())
        defer { fixture.close() }
        let asset = try #require(
            await fixture.loader.image(
                url: URL(string: "https://pictures.invalid/native")!, pixels: 480))
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [],
            backing: .buffered, defer: false)
        let surface = CommentImageSurface()
        window.contentView = surface
        defer {
            surface.stop()
            window.contentView = nil
        }
        surface.update(asset: asset, contentMode: .fit, animates: true)
        surface.layoutSubtreeIfNeeded()
        let image = surface.imageView.image
        #expect(surface.imageView.animates)
        #expect(surface.imageView.frame == CGRect(x: 0, y: 50, width: 200, height: 100))
        #expect(surface.hitTest(NSPoint(x: 50, y: 50)) == nil)
        surface.update(asset: asset, contentMode: .fill, animates: false)
        surface.layoutSubtreeIfNeeded()
        #expect(!surface.imageView.animates)
        #expect(surface.imageView.frame == CGRect(x: -100, y: 0, width: 400, height: 200))
        #expect(surface.imageView.image === image)
        surface.update(asset: asset, contentMode: .fill, animates: true)
        surface.isHidden = true
        #expect(!surface.imageView.animates)
        surface.isHidden = false
        #expect(surface.imageView.animates)
        window.contentView = nil
        #expect(!surface.imageView.animates)
        surface.stop()
        #expect(surface.imageView.image == nil)

        // Scroll clipping must stop offscreen GIFs even when their comment rows are retained.
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 500))
        let scrolledImage = CommentImageSurface()
        scrolledImage.frame = CGRect(x: 0, y: 300, width: 200, height: 100)
        document.addSubview(scrolledImage)
        scroll.documentView = document
        window.contentView = scroll
        defer { scrolledImage.stop() }
        scroll.contentView.scroll(to: .zero)
        scrolledImage.update(asset: asset, contentMode: .fit, animates: true)
        scrolledImage.layoutSubtreeIfNeeded()
        #expect(!scrolledImage.imageView.animates)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 250))
        #expect(scrolledImage.imageView.animates)
        scroll.contentView.scroll(to: .zero)
        #expect(!scrolledImage.imageView.animates)
    }

    /// Actual AppKit timers need a visible window; run explicitly on a desktop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_COMMENT_GIF_TEST"] == "1"))
    func nativeGIFActuallyAdvancesAndPauses() async throws {
        let fixture = CommentImageFixture(data: try commentGIFFixture())
        defer { fixture.close() }
        let asset = try #require(
            await fixture.loader.image(
                url: URL(string: "https://pictures.invalid/playing")!, pixels: 480))
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        let surface = CommentImageSurface()
        window.contentView = surface
        surface.update(asset: asset, contentMode: .fit, animates: true)
        window.orderFront(nil)
        defer {
            surface.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        let bitmap = try #require(
            surface.imageView.image?.representations.first as? NSBitmapImageRep)
        var frames = Set<Int>()
        var colors = Set<String>()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            frames.insert((bitmap.value(forProperty: .currentFrame) as? NSNumber)?.intValue ?? -1)
            surface.layoutSubtreeIfNeeded()
            let rendered = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: rendered)
            let color = try #require(
                rendered.colorAt(x: rendered.pixelsWide / 2, y: rendered.pixelsHigh / 2)?
                    .usingColorSpace(.deviceRGB))
            if color.redComponent > 0.8 && color.blueComponent < 0.2 { colors.insert("red") }
            if color.blueComponent > 0.8 && color.redComponent < 0.2 { colors.insert("blue") }
        }
        #expect(frames == [0, 1])
        #expect(colors == ["red", "blue"])
        surface.update(asset: asset, contentMode: .fit, animates: false)
        let paused = bitmap.value(forProperty: .currentFrame) as? NSNumber
        try await Task.sleep(for: .milliseconds(250))
        #expect(bitmap.value(forProperty: .currentFrame) as? NSNumber == paused)
    }
}

private func commentGIFFixture(type: UTType = .gif) throws -> Data {
    let data = NSMutableData()
    let count = type == .gif ? 2 : 1
    let destination = try #require(
        CGImageDestinationCreateWithData(data, type.identifier as CFString, count, nil))
    CGImageDestinationSetProperties(
        destination,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for color in [
        CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1),
    ].prefix(count) {
        let context = try #require(
            CGContext(
                data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 0.1, kCGImagePropertyGIFUnclampedDelayTime: 0.1,
                ]
            ] as CFDictionary)
    }
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private final class CommentImageFixture: @unchecked Sendable {
    let loader: CommentImageStore.Requests
    private let session: URLSession
    private let lock = NSLock()
    private var requests = 0
    private var cancelled = 0
    private var responseStatus = 200
    var count: Int { lock.withLock { requests } }
    var stops: Int { lock.withLock { cancelled } }
    var status: Int {
        get { lock.withLock { responseStatus } }
        set { lock.withLock { responseStatus = newValue } }
    }

    init(data: Data) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentImageProtocol.self]
        session = URLSession(configuration: config)
        loader = CommentImageStore.Requests(session: session)
        CommentImageProtocol.respond = { [weak self] connection in
            guard let self else { return }
            let status = self.lock.withLock {
                self.requests += 1
                return self.responseStatus
            }
            connection.cancelled = { [weak self] in self?.lock.withLock { self?.cancelled += 1 } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
                guard !connection.stopped else { return }
                connection.client?.urlProtocol(
                    connection,
                    didReceive: HTTPURLResponse(
                        url: connection.request.url!, statusCode: status, httpVersion: nil,
                        headerFields: nil)!,
                    cacheStoragePolicy: .notAllowed)
                connection.client?.urlProtocol(connection, didLoad: data)
                connection.client?.urlProtocolDidFinishLoading(connection)
            }
        }
    }

    func close() {
        session.invalidateAndCancel()
        CommentImageProtocol.respond = nil
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<100 {
            if self.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(self.count >= count)
    }
}

private final class CommentImageProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((CommentImageProtocol) -> Void)?
    private let lock = NSLock()
    private var didStop = false
    var cancelled: (() -> Void)?
    var stopped: Bool { lock.withLock { didStop } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "pictures.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.respond?(self) }
    override func stopLoading() {
        lock.withLock { didStop = true }
        cancelled?()
    }
}
