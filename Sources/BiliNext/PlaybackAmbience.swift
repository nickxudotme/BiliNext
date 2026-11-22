import SwiftUI

/// A stable playback canvas with no artwork decoding, blur or backdrop sampling.
struct PlaybackAmbience: View {
    var body: some View {
        GlassTheme.playbackBackground
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The existing inset panel geometry with a solid reading surface.
struct FloatingGlassPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
        content
            .clipShape(shape)
            .background(GlassTheme.playbackPanel, in: shape)
            .overlay {
                shape.strokeBorder(
                    .white.opacity(contrast == .increased ? 0.35 : 0.08), lineWidth: 1
                ).allowsHitTesting(false)
            }
    }
}

extension View {
    func floatingGlassPanel() -> some View { modifier(FloatingGlassPanel()) }
}

/// The player's controls as one opaque bar inset from the picture's edges,
/// shared by on-demand and live playback.
struct PlayerGlassBar: ViewModifier {
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 16 : 22)
        content
            .padding(.horizontal, compact ? 8 : 14).padding(.top, compact ? 4 : 6)
            .padding(.bottom, compact ? 4 : 8)
            .background(GlassTheme.playbackControls, in: shape)
            .overlay {
                shape.strokeBorder(
                    .white.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 1
                ).allowsHitTesting(false)
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, compact ? 8 : 18).padding(.bottom, compact ? 8 : 16)
    }
}

extension View {
    func playerGlassBar(compact: Bool = false) -> some View {
        modifier(PlayerGlassBar(compact: compact))
    }
}
