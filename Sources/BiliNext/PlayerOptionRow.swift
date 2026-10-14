import SwiftUI

struct PlayerOptionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(GlassTheme.labelFont)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(GlassTheme.captionFont.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(selected ? GlassTheme.accent : .primary)
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
