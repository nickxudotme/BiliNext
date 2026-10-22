import AppKit
import SwiftUI

/// One material per floating surface; controls inside keep a quiet, readable background.
struct FeedbackGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor), in: shape)
            } else if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            if reduceTransparency || contrast == .increased {
                shape.strokeBorderFallback.opacity(contrast == .increased ? 0.5 : 0.15)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func feedbackGlass<S: Shape>(in shape: S) -> some View {
        modifier(FeedbackGlassSurface(shape: shape))
    }
}

extension Shape {
    fileprivate var strokeBorderFallback: some View { stroke(.primary, lineWidth: 1) }
}
