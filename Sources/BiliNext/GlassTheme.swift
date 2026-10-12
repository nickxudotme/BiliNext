import AppKit
import SwiftUI

/// Glass belongs to navigation and controls; artwork stays on a quiet, opaque canvas.
enum GlassTheme {
    static let contentInset: CGFloat = 28
    static let artworkRadius: CGFloat = 12
    static let rowRadius: CGFloat = 8
    static let panelRadius: CGFloat = 16
    static let readingFont = Font.system(size: 16)
    static let bodyFont = Font.system(size: 15)
    static let labelFont = Font.system(size: 14)
    static let metadataFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 12)
    static let controlHeight: CGFloat = 34
    static let iconControlSize: CGFloat = 32
    static let navigationRowHeight: CGFloat = 38
    static let childRowHeight: CGFloat = 34
    static let tabRowHeight: CGFloat = 36
    static let accent = Color.pink
    static let canvas = Color(nsColor: .windowBackgroundColor)
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

struct SidebarSurface: View {
    let pinned: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: pinned ? 0 : GlassTheme.panelRadius)
        Group {
            if reduceTransparency {
                shape.fill(GlassTheme.canvas)
            } else {
                // A material foundation lets the glass controls above it remain legible.
                shape.fill(.thinMaterial)
            }
        }
        .overlay {
            shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.30 : 0.08), lineWidth: 1)
        }
    }
}

struct DetailSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            GlassTheme.canvas
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

struct NavigationSelection: View {
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
            .fill(.primary.opacity(selected ? 0.10 : 0))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                        .strokeBorder(
                            .primary.opacity(contrast == .increased ? 0.45 : 0.10), lineWidth: 1)
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
