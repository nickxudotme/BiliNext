import BiliNextCore
import SwiftUI

struct LiveChatRow: View {
    let message: LiveChatMessage
    var body: some View {
        Text("\(Text(message.user).foregroundStyle(.secondary))：\(Text(message.message))")
            .font(GlassTheme.bodyFont).lineSpacing(3)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
