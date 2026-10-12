import CoreGraphics
import Foundation

/// A copied video-only mpv frame. No overlays or screen recording permissions are involved.
struct SubtitleFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    var image: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
