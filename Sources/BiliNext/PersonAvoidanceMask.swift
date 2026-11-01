import CoreImage
import SwiftUI
import Vision

private actor PersonMaskWorker {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    func mask(_ frame: SubtitleFrame) throws -> CGImage? {
        guard let image = frame.image else { return nil }
        let input = CIImage(cgImage: image)
        let ratio = min(1, 384 / Double(frame.width))
        let small = input.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        try VNImageRequestHandler(ciImage: small).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let person = CIImage(cvPixelBuffer: buffer)
        let inverse = CIImage(color: .clear).cropped(to: person.extent).applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: person.extent),
                kCIInputMaskImageKey: person,
            ])
        return context.createCGImage(inverse, from: person.extent)
    }
}

struct PersonAvoidanceMask: ViewModifier {
    let player: MPVPlayer?
    let active: Bool
    @AppStorage("danmaku.personAvoidance") private var enabled = false
    @State private var mask: CGImage?
    @State private var aspect = 16.0 / 9.0
    // Most sessions never enable this feature. Build Vision/Core Image resources only
    // when masking first runs, then retain them across pause/resume cycles.
    @State private var worker: PersonMaskWorker?

    func body(content: Content) -> some View {
        Group {
            if enabled && active {
                content.mask {
                    GeometryReader { geometry in
                        if enabled, active, let mask {
                            let width = min(geometry.size.width, geometry.size.height * aspect)
                            let height = width / aspect
                            let vertical = max(0, (geometry.size.height - height) / 2)
                            let horizontal = max(0, (geometry.size.width - width) / 2)
                            VStack(spacing: 0) {
                                Color.white.frame(height: vertical)
                                HStack(spacing: 0) {
                                    Color.white.frame(width: horizontal)
                                    Image(decorative: mask, scale: 1).resizable().frame(
                                        width: width, height: height)
                                    Color.white.frame(width: horizontal)
                                }
                                Color.white.frame(height: vertical)
                            }
                        } else {
                            Color.white
                        }
                    }
                }
            } else {
                content
            }
        }
        .task(id: "\(enabled):\(active):\(player?.diagnosticContext?.session.uuidString ?? "none")")
        {
            mask = nil
            guard enabled, active, let player else { return }
            if worker == nil { worker = PersonMaskWorker() }
            guard let worker else { return }
            while !Task.isCancelled {
                if player.playing, !player.flag("paused-for-cache"),
                    NSApp.isActive, let frame = await player.subtitleFrame()
                {
                    do {
                        let image = try await worker.mask(frame)
                        try Task.checkCancellation()
                        mask = image
                        aspect = Double(frame.width) / Double(max(1, frame.height))
                    } catch { if !Task.isCancelled { mask = nil } }
                }
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            }
        }
    }
}
