import SwiftUI

private struct CardGridScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardGridScrolling: Bool {
        get { self[CardGridScrollingKey.self] }
        set { self[CardGridScrollingKey.self] = newValue }
    }
}

/// Shared pointer feedback, with local state so hovering a card does not refresh the page.
struct InteractionButtonStyle: ButtonStyle {
    enum Kind { case control, row, card }
    var kind: Kind = .control
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, kind: kind, destructive: destructive)
    }

    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.cardGridScrolling) private var scrolling
        @State private var hovered = false

        private var highlighted: Bool { enabled && hovered && !scrolling }
        private var pressed: Bool { enabled && configuration.isPressed }
        private var tint: Color { destructive ? .red : .primary }
        private var radius: CGFloat {
            switch kind {
            case .control: 7
            case .row: 6
            case .card: 12
            }
        }

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(tint.opacity(pressed ? 0.14 : highlighted ? 0.065 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(tint.opacity(highlighted || pressed ? 0.10 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .scaleEffect(reduceMotion ? 1 : pressed ? (kind == .card ? 0.985 : 0.96) : 1)
                .offset(y: !reduceMotion && kind == .card && highlighted && !pressed ? -2 : 0)
                .opacity(enabled ? 1 : 0.45)
                .animation(
                    reduceMotion || scrolling ? nil : .easeOut(duration: pressed ? 0.09 : 0.16),
                    value: hovered
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
                .onHover { hovered = $0 }
        }
    }
}

/// Menus keep native opening/press behavior while gaining the same pointer highlight.
struct MenuHoverFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.overlay {
            Circle().strokeBorder(.primary.opacity(hovered ? 0.18 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .onHover { hovered = $0 }
    }
}
