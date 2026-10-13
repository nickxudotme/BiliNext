import AppKit
import BiliNextCore
import CoreText
import SwiftUI

struct LiveDanmakuOverlay: View {
    @ObservedObject var chat: LiveChatModel
    let playing: Bool
    @AppStorage("danmaku.enabled") private var enabled = true
    @AppStorage("danmaku.opacity") private var opacity = 0.85
    @AppStorage("danmaku.font") private var font = 20.0
    @AppStorage("danmaku.area") private var area = 0.5
    @AppStorage("danmaku.speed") private var speed = 1.0
    @AppStorage("danmaku.blocked") private var blocked = ""
    @AppStorage("danmaku.rolling") private var rolling = true

    var body: some View {
        GeometryReader { geometry in
            LiveDanmakuSurface(
                messages: chat.liveMessages, playing: playing, enabled: enabled && rolling,
                opacity: opacity,
                configuration: .init(
                    size: geometry.size, font: font, area: area, speed: speed, blocked: blocked))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct LiveDanmakuSurface: NSViewRepresentable {
    struct Configuration: Equatable {
        let size: CGSize
        let font: Double
        let area: Double
        let speed: Double
        let blocked: String
    }
    let messages: [LiveChatMessage]
    let playing: Bool
    let enabled: Bool
    let opacity: Double
    let configuration: Configuration

    final class Coordinator {
        var timeline = LiveDanmakuTimeline()
        var configuration: Configuration?
        var seen = Set<String>()
        var elapsed = 0.0
        var host = CACurrentMediaTime()
        var running = false
        func time() -> Double { elapsed + (running ? CACurrentMediaTime() - host : 0) }
        func setRunning(_ value: Bool) {
            elapsed = time()
            host = CACurrentMediaTime()
            running = value
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DanmakuSurface.Surface {
        let view = DanmakuSurface.Surface()
        let clock = context.coordinator
        view.liveClock = { [weak clock] in clock?.time() ?? 0 }
        return view
    }
    func updateNSView(_ view: DanmakuSurface.Surface, context: Context) {
        let clock = context.coordinator
        clock.setRunning(playing && enabled)
        let time = clock.time()
        let reset = clock.configuration != configuration || !enabled
        if reset {
            clock.configuration = configuration
            clock.timeline.reset()
            view.items = []
            for label in view.labels.values { label.removeFromSuperlayer() }
            view.labels.removeAll()
        }
        let incoming = messages.filter { !clock.seen.contains($0.id) }
        clock.seen = Set(messages.map(\.id))
        let words = configuration.blocked.components(
            separatedBy: CharacterSet(charactersIn: ",，\n")
        )
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // History and comments received while paused are never replayed over the video.
        let comments: [Danmaku] =
            playing && enabled && !reset
            ? incoming.compactMap { message in
                guard
                    !words.contains(where: { message.message.localizedCaseInsensitiveContains($0) })
                else { return nil }
                return Danmaku(
                    id: message.id, time: time, mode: 1, fontSize: 25,
                    color: message.color, text: message.message)
            } : []
        let font = CTFontCreateWithName(
            NSFont.systemFont(ofSize: configuration.font, weight: .semibold).fontName as CFString,
            configuration.font, nil)
        let lanes = max(
            1, Int((configuration.size.height - 80) * configuration.area / (configuration.font + 8))
        )
        view.items = clock.timeline.append(
            comments, at: time, viewport: configuration.size.width,
            lanes: lanes, duration: 8 / max(0.1, configuration.speed)
        ) { comment in
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: comment.text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            return ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 4
        }
        view.maximumDuration = 8 / max(0.1, configuration.speed)
        view.fontSize = configuration.font
        view.fixed = false
        view.running = playing && enabled
        view.enabled = enabled
        view.layer?.opacity = Float(opacity)
        view.layer?.isHidden = !enabled
        view.displayLink?.isPaused = !view.running
        view.render(time: time)
    }
    static func dismantleNSView(_ view: DanmakuSurface.Surface, coordinator: Coordinator) {
        view.displayLink?.invalidate()
        view.displayLink = nil
        view.liveClock = nil
    }
}
