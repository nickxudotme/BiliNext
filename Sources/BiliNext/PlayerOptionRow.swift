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
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background { NavigationSelection(selected: selected) }
        }
        .buttonStyle(InteractionButtonStyle(kind: .row))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
