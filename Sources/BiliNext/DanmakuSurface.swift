import AVFoundation
import AppKit
import BiliNextCore
import CoreText
import SwiftUI

struct DanmakuCanvas: View {
    let player: AVPlayer
    let mpv: MPVPlayer?
    @ObservedObject var model: DanmakuModel
    let time: Double
    let playing: Bool
    let opacity: Double
    let fontSize: Double
    let area: Double
    let speed: Double
    let blocked: String
    let rolling: Bool
    let fixed: Bool
    @State private var placements: [DanmakuPlacement] = []
    @State private var layoutID = UUID()
    var body: some View {
        GeometryReader { geometry in
            DanmakuSurface(
                player: player, mpv: mpv, placements: placements, layoutID: layoutID,
                playing: playing && model.enabled, enabled: model.enabled, time: time,
                opacity: opacity, fontSize: fontSize, fixed: fixed
            )
            .task(
                id:
                    "\(geometry.size):\(fontSize):\(area):\(speed):\(blocked):\(rolling):\(fixed):\(model.revision)"
            ) {
                let comments = model.comments
                let viewport = Double(geometry.size.width)
                let height = Double(geometry.size.height)
                let fontName = NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontName
                let work = Task.detached(priority: .userInitiated) { () -> [DanmakuPlacement] in
                    let words = blocked.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let items = comments.filter { $0.mode >= 4 ? fixed : rolling }
                    let filtered = items.filter { comment in
                        !words.contains { comment.text.localizedCaseInsensitiveContains($0) }
                    }
                    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
                    var widths: [String: Double] = [:]
                    let reserved: Double = fixed ? 4 * (fontSize + 8) : 0
                    let lanes = max(1, Int((height - 80 - reserved) * area / (fontSize + 8)))
                    return DanmakuLayout.arrange(
                        filtered, viewport: viewport, lanes: lanes, duration: 8 / speed
                    ) { comment -> Double in
                        if let width = widths[comment.text] { return width }
                        let line = CTLineCreateWithAttributedString(
                            NSAttributedString(
                                string: comment.text,
                                attributes: [
                                    NSAttributedString.Key(kCTFontAttributeName as String): font
                                ]))
                        let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 4
                        widths[comment.text] = width
                        return width
                    }
                }
                let result = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled else { return }
                placements = result
                layoutID = UUID()
            }
        }.clipped().accessibilityHidden(true)
    }
}

struct DanmakuSurface: NSViewRepresentable {
    let player: AVPlayer
    let mpv: MPVPlayer?
    let placements: [DanmakuPlacement]
    let layoutID: UUID
    let playing: Bool
    let enabled: Bool
    let time: Double
    let opacity: Double
    let fontSize: Double
    let fixed: Bool
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        if view.layoutID != layoutID {
            view.layoutID = layoutID
            view.items = placements
            view.maximumDuration = placements.map(\.duration).max() ?? 0
            for label in view.labels.values { label.removeFromSuperlayer() }
            view.labels.removeAll()
        }
        view.player = mpv == nil ? player : nil
        view.mpv = mpv
        view.fontSize = fontSize
        view.fixed = fixed
        view.layer?.opacity = Float(opacity)
        view.layer?.isHidden = !enabled
        view.running = playing
        view.enabled = enabled
        view.displayLink?.isPaused = !playing
        view.render(
            time: mpv?.time
                ?? (player.currentItem?.status == .readyToPlay
                    ? player.currentTime().seconds : time))
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        view.displayLink?.invalidate()
        view.displayLink = nil
    }
    final class Surface: NSView {
        override var isFlipped: Bool { true }
        var liveClock: (() -> Double)?
        var player: AVPlayer?
        weak var mpv: MPVPlayer?
        var items: [DanmakuPlacement] = []
        var labels: [String: CALayer] = [:]
        var layoutID: UUID?
        var maximumDuration = 0.0
        var fontSize = 20.0
        var fixed = true
        var running = false
        var enabled = true
        var displayLink: CADisplayLink?
        private var lastTime = Double.nan
        private var lastHost = 0.0
        private var lastRate: Float = -1
        private var lastSize = CGSize.zero
        private var lastScale = 0.0
        private let textures = NSCache<NSString, Texture>()
        private final class Texture: NSObject {
            let image: CGImage
            let size: CGSize
            init(image: CGImage, size: CGSize) {
                self.image = image
                self.size = size
            }
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            textures.countLimit = 512
            textures.totalCostLimit = 32 * 1024 * 1024
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            if window != nil {
                let link = self.displayLink(target: self, selector: #selector(tick))
                // The compositor moves textures at the display's refresh rate. This clock
                // only admits/removes comments and resynchronizes after a seek or rate change.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 15, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                link.isPaused = !running
                displayLink = link
            }
        }
        @objc private func tick() {
            if let liveClock {
                render(time: liveClock())
            } else if let mpv {
                render(time: mpv.time)
            } else if let player {
                render(time: player.currentTime().seconds)
            }
        }
        private func lowerBound(_ value: Double) -> Int {
            var low = 0
            var high = items.count
            while low < high {
                let middle = (low + high) / 2
                if items[middle].comment.time < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
        private func texture(for item: DanmakuPlacement, scale: Double) -> Texture? {
            let key = "\(fontSize):\(scale):\(item.comment.color):\(item.comment.text)" as NSString
            if let cached = textures.object(forKey: key) { return cached }
            let size = CGSize(width: ceil(item.width + 8), height: ceil(fontSize + 12))
            let width = Int(ceil(size.width * scale))
            let height = Int(ceil(size.height * scale))
            guard width > 0, height > 0, width <= 32768,
                let context = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            let c = item.comment.color
            let color = NSColor(
                red: Double(c >> 16 & 255) / 255,
                green: Double(c >> 8 & 255) / 255, blue: Double(c & 255) / 255, alpha: 1)
            let font = CTFontCreateWithName(
                NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontName as CFString,
                fontSize, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: item.comment.text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
                            .cgColor,
                    ]))
            context.textPosition = CGPoint(x: 4, y: 4 + CTFontGetDescent(font))
            context.setShadow(
                offset: CGSize(width: 1, height: -1), blur: 1,
                color: NSColor.black.withAlphaComponent(0.95).cgColor)
            CTLineDraw(line, context)
            guard let image = context.makeImage() else { return nil }
            let result = Texture(image: image, size: size)
            textures.setObject(result, forKey: key, cost: width * height * 4)
            return result
        }
        func render(time: Double) {
            guard time.isFinite, enabled else { return }
            let host = CACurrentMediaTime()
            let advancing = running && (player == nil || player?.timeControlStatus == .playing)
            let rate: Float = advancing ? Float(mpv?.speed ?? Double(player?.rate ?? 1)) : 0
            let scale = window?.backingScaleFactor ?? 2
            let expected = lastTime + (host - lastHost) * Double(lastRate)
            let resync =
                !lastTime.isFinite || abs(time - expected) > 0.15
                || rate != lastRate || bounds.size != lastSize || scale != lastScale
            if resync {
                lastTime = time
                lastHost = host
            }
            lastRate = rate
            lastSize = bounds.size
            lastScale = scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var active = Set<String>()
            var index = lowerBound(time - maximumDuration)
            while index < items.count && items[index].comment.time <= time {
                let item = items[index]
                index += 1
                guard item.visible(at: time) else { continue }
                active.insert(item.id)
                let text: CALayer
                let fresh: Bool
                if let cached = labels[item.id] {
                    text = cached
                    fresh = false
                } else {
                    guard let texture = texture(for: item, scale: scale) else { continue }
                    text = CALayer()
                    text.contents = texture.image
                    text.contentsScale = scale
                    text.anchorPoint = .zero
                    text.bounds = CGRect(origin: .zero, size: texture.size)
                    layer?.addSublayer(text)
                    labels[item.id] = text
                    fresh = true
                }
                // Leave existing animations untouched during regular scheduler ticks.
                guard fresh || resync else { continue }
                text.removeAnimation(forKey: "scroll")
                let row =
                    Double(item.lane + (item.comment.mode < 4 && fixed ? 2 : 0))
                    * (fontSize + 8) + 10
                let y = max(8, item.comment.mode == 4 ? bounds.height - row - fontSize - 80 : row)
                let x = item.x(at: time, viewport: bounds.width) - 4
                text.position = CGPoint(x: x, y: y)
                if item.comment.mode < 4 && rate > 0 {
                    let remaining = item.comment.time + item.duration - time
                    let animation = CABasicAnimation(keyPath: "position.x")
                    animation.fromValue = x
                    animation.toValue = -item.width - 4
                    animation.duration = remaining / Double(rate)
                    animation.timingFunction = CAMediaTimingFunction(name: .linear)
                    animation.isRemovedOnCompletion = false
                    animation.fillMode = .forwards
                    text.add(animation, forKey: "scroll")
                }
            }
            for id in Array(labels.keys) where !active.contains(id) {
                labels.removeValue(forKey: id)?.removeFromSuperlayer()
            }
            CATransaction.commit()
        }
    }
}
