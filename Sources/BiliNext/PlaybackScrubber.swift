import BiliNextCore
import SwiftUI

/// Bilibili-style progress bar: a thin track that thickens on hover, buffered range, a knob
/// that pops in on hover, a time bubble that follows the pointer, and an optional
/// 高能进度条 (viewer-activity curve) above the track.
struct PlaybackScrubber: View {
    let time: Double
    let duration: Double
    let buffered: Double
    /// Normalised activity samples spread evenly across the video, or empty when unknown.
    var activity: [Double] = []
    var showsActivity = false
    /// 看点 chapters: the track breaks between them and the bubble names the one under it.
    var chapters: [ViewPoint] = []
    @Binding var scrubbing: Bool
    @Binding var scrubTime: Double
    let seek: (Double) -> Void
    var interact: () -> Void = {}

    @State private var hoverX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let activityHeight: CGFloat = 26
    private var engaged: Bool { hoverX != nil || scrubbing }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let shown = scrubbing ? scrubTime : time
            let played = fraction(shown) * width
            ZStack(alignment: .bottomLeading) {
                if showsActivity && !activity.isEmpty {
                    ActivityCurve(samples: activity)
                        .fill(.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            ActivityCurve(samples: activity)
                                .fill(GlassTheme.accent.opacity(0.55))
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: played)
                                }
                        }
                        .frame(height: Self.activityHeight)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                track(width: width, played: played)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
                if engaged, duration > 0 {
                    let x = scrubbing ? played : (hoverX ?? played)
                    let seconds = fraction(at: x, width: width) * duration
                    let chapter = ViewPoint.containing(seconds, in: chapters)?.title
                    bubble(seconds: seconds, chapter: chapter)
                        .position(
                            x: min(max(x, 28), width - 28),
                            // A chapter title adds a line; grow upwards, clear of the track.
                            y: proxy.size.height - 34 - (chapter == nil ? 0 : 8)
                                - (showsActivity ? Self.activityHeight : 0)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverX = point.x
                    interact()
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = true
                        scrubTime = fraction(at: value.location.x, width: width) * duration
                        interact()
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let target = fraction(at: value.location.x, width: width) * duration
                        scrubTime = target
                        seek(target)
                        scrubbing = false
                        interact()
                    })
        }
        .frame(height: 28 + (showsActivity && !activity.isEmpty ? Self.activityHeight : 0))
        .animation(Motion.quick(reduceMotion), value: engaged)
        .animation(Motion.standard(reduceMotion), value: showsActivity)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { time }, set: { seek($0) }), in: 0...max(1, duration)
            ) { Text("播放进度") }
        }
    }

    private func track(width: CGFloat, played: CGFloat) -> some View {
        let height: CGFloat = engaged ? 6 : 4
        return Capsule().fill(.white.opacity(0.22))
            .frame(height: height)
            .overlay(alignment: .leading) {
                Capsule().fill(.white.opacity(0.32)).frame(width: fraction(buffered) * width)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(GlassTheme.accent).frame(width: max(height, played))
            }
            .mask {
                ChapterBreaks(
                    starts: chapters.map { fraction($0.start) }.filter { $0 > 0.002 && $0 < 0.998 }
                )
                .fill(style: FillStyle(eoFill: true))
            }
            // The knob is an overlay so its size never changes the track's height.
            .overlay(alignment: .leading) {
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(engaged ? 1 : 0.01)
                    .offset(x: min(max(0, played - 7), width - 14))
            }
    }

    private func bubble(seconds: Double, chapter: String?) -> some View {
        VStack(spacing: 1) {
            if let chapter {
                Text(chapter).font(GlassTheme.captionFont.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: 220).fixedSize()
            }
            Text(timestamp(seconds)).font(GlassTheme.captionFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(chapter == nil ? .white : .white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard duration > 0, seconds.isFinite else { return 0 }
        return CGFloat(min(1, max(0, seconds / duration)))
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(1, max(0, x / width)))
    }
}

/// The track's mask: the full width, less a 2pt gap at each chapter start.
private struct ChapterBreaks: Shape {
    let starts: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for start in starts {
            path.addRect(
                CGRect(x: rect.width * start - 1, y: rect.minY, width: 2, height: rect.height))
        }
        return path
    }
}

/// A smooth area chart of activity samples, filling the shape's frame.
struct ActivityCurve: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let peak = max(samples.max() ?? 1, .ulpOfOne)
        let step = rect.width / CGFloat(samples.count - 1)
        let points = samples.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - CGFloat(value / peak) * rect.height)
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: points[0])
        for (previous, point) in zip(points, points.dropFirst()) {
            let middle = (previous.x + point.x) / 2
            path.addCurve(
                to: point, control1: CGPoint(x: middle, y: previous.y),
                control2: CGPoint(x: middle, y: point.y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
