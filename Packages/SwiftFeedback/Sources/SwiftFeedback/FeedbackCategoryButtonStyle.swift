import SwiftUI

/// Explicit fills avoid the macOS bordered button's tint-only selected appearance.
struct FeedbackCategoryButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    shape.fill(FeedbackStyle.green)
                } else {
                    shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                }
            }
            .overlay {
                shape.stroke(
                    selected
                        ? Color.white.opacity(0.35)
                        : Color.primary.opacity(contrast == .increased ? 0.5 : 0.12),
                    lineWidth: 1)
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
