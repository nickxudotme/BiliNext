import BiliNextCore
import SwiftUI

/// The playback page's ambient light: the current cover, heavily blurred and deepened, so
/// the glass details panel above takes on each video's colour. Falls back to a plain dark
/// surface under Reduce Transparency.
struct PlaybackAmbience: View {
    let cover: URL?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(white: 0.07)
            if !reduceTransparency {
                ThumbnailView(url: cover, pixels: 96) { Color.clear }
                    .id(cover)
                    .scaledToFill()
                    .scaleEffect(1.6)
                    .blur(radius: 70, opaque: true)
                    .saturation(1.5)
                    .opacity(0.85)
                    .transition(.opacity)
                // Deepen towards the edges so text on the glass stays legible.
                LinearGradient(
                    colors: [.black.opacity(0.25), .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: cover)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A floating Liquid Glass sheet for panels over the ambient light.
struct FloatingGlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
        content
            .clipShape(shape)
            .background {
                if reduceTransparency {
                    shape.fill(Color(white: 0.12))
                } else {
                    Color.clear.glassEffect(.regular.tint(.black.opacity(0.18)), in: shape)
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

extension View {
    func floatingGlassPanel() -> some View { modifier(FloatingGlassPanel()) }
}

/// The player's controls as one floating Liquid Glass bar inset from the picture's edges,
/// shared by on-demand and live playback.
struct PlayerGlassBar: ViewModifier {
    var compact = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 16 : 22)
        content
            .padding(.horizontal, compact ? 8 : 14).padding(.top, compact ? 4 : 6)
            .padding(.bottom, compact ? 4 : 8)
            .background {
                if reduceTransparency {
                    shape.fill(.black.opacity(0.8))
                } else {
                    Color.clear.glassEffect(.regular.tint(.black.opacity(0.3)), in: shape)
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .frame(maxWidth: 1040)
            .padding(.horizontal, compact ? 8 : 18).padding(.bottom, compact ? 8 : 16)
    }
}

extension View {
    func playerGlassBar(compact: Bool = false) -> some View {
        modifier(PlayerGlassBar(compact: compact))
    }
}
