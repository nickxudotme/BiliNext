import AppKit
import SwiftUI

/// Glass belongs to navigation and controls; artwork stays on a quiet, opaque canvas.
/// Pink marks state (selection, hover, progress, activated actions), never resting chrome.
enum GlassTheme {
    static let contentInset: CGFloat = 28
    static let badgeRadius: CGFloat = 4
    static let artworkRadius: CGFloat = 12
    static let rowRadius: CGFloat = 8
    static let panelRadius: CGFloat = 16
    /// Gap between the window edge and the content card, and the card's concentric corner.
    static let cardGap: CGFloat = 10
    static let cardRadius: CGFloat = 10

    static let pageTitleFont = Font.system(size: 26, weight: .bold)
    static let sheetTitleFont = Font.system(size: 20, weight: .bold)
    static let sectionTitleFont = Font.system(size: 17, weight: .semibold)
    static let readingFont = Font.system(size: 16)
    static let bodyFont = Font.system(size: 15)
    static let labelFont = Font.system(size: 14)
    static let metadataFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 12)

    /// SF Symbol sizes: small disclosure/close glyphs, regular toolbar icons, player icons.
    static let smallIconFont = Font.system(size: 11, weight: .semibold)
    static let iconFont = Font.system(size: 15)
    static let largeIconFont = Font.system(size: 18)

    static let controlHeight: CGFloat = 34
    static let iconControlSize: CGFloat = 32
    static let navigationRowHeight: CGFloat = 38
    static let childRowHeight: CGFloat = 34
    static let tabRowHeight: CGFloat = 36

    /// Bilibili pink, slightly deeper in dark appearance so white labels stay legible.
    static let accent = Color(
        nsColor: NSColor(name: "BiliNextAccent") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.93, green: 0.36, blue: 0.55, alpha: 1)
                : NSColor(srgbRed: 1.00, green: 0.40, blue: 0.60, alpha: 1)
        })
    static let canvas = Color(nsColor: .textBackgroundColor)
    /// A raised selection inside the card: white in light appearance, a lifted grey in dark.
    static let raisedFill = Color(
        nsColor: NSColor(name: "BiliNextRaised") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.16) : .white
        })

    /// One pointer-feedback scale for every control, row and card.
    static let hoverOpacity = 0.07
    static let pressOpacity = 0.14
    static let selectionOpacity = 0.14
}

/// Motion speeds: hover/press feedback, standard state changes and larger layout moves.
/// `quick` and `panel` follow Arc's measured values: 0.1s fades and a 0.08s
/// cubic-bezier(0.25, 0.46, 0.45, 0.94) for the sidebar showing, hiding and floating.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.1)
    static let panel = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.08)
    /// State changes and larger moves use native springs.
    static let standard = Animation.snappy(duration: 0.25)
    static let emphasized = Animation.smooth(duration: 0.4)

    static func quick(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : quick }
    static func panel(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : panel }
    static func standard(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : standard }
    static func emphasized(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : emphasized
    }
}

struct ChromeSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(GlassTheme.canvas, in: shape)
            } else {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        }
        .overlay {
            if reduceTransparency || contrast == .increased {
                shape.stroke(.primary.opacity(contrast == .increased ? 0.35 : 0.14), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Pinned, the sidebar sits directly on the window backdrop. Revealed from the edge,
/// it floats over content as a glass panel.
struct SidebarSurface: View {
    let pinned: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
        if pinned {
            Color.clear
        } else {
            Group {
                if reduceTransparency {
                    shape.fill(GlassTheme.canvas)
                } else {
                    Color.clear.glassEffect(
                        .regular.tint(GlassTheme.canvas.opacity(0.45)), in: shape)
                }
            }
            .overlay {
                shape.strokeBorder(
                    .primary.opacity(contrast == .increased ? 0.30 : 0.08), lineWidth: 1)
            }
        }
    }
}

/// Panels inside the content card share its opaque canvas; material over an opaque card
/// only reads as grey.
struct DetailSurface: View {
    var body: some View { GlassTheme.canvas }
}

/// A selected sidebar row is a small piece of the content card it opens, as in Arc:
/// card-coloured, lifted by a hairline shadow. The outline returns under Increase Contrast.
struct NavigationSelection: View {
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
            .fill(GlassTheme.canvas.opacity(selected ? 1 : 0))
            .shadow(color: .black.opacity(selected ? 0.16 : 0), radius: 1, y: 0.5)
            .overlay {
                if selected && contrast == .increased {
                    RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                        .strokeBorder(.primary.opacity(0.45), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
    }
}

extension View {
    func iconControlFrame(size: CGFloat = GlassTheme.iconControlSize) -> some View {
        frame(width: size, height: size).contentShape(Rectangle())
    }

    func chromeSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(ChromeSurface(shape: shape, interactive: interactive))
    }
}
