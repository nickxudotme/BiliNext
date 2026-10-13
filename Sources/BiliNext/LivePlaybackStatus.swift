import SwiftUI

struct LivePlaybackStatus: View {
    let title: String
    let message: String
    let symbol: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28))
            Text(title).font(GlassTheme.readingFont.weight(.semibold))
            Text(message).font(GlassTheme.bodyFont).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("重新连接", action: retry).buttonStyle(.bordered)
        }.foregroundStyle(.white).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.8))
    }
}
