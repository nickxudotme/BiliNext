import SwiftUI

/// A soft highlight that sweeps across placeholders while content loads.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.10), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .rotationEffect(.degrees(12))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Placeholder cards laid out exactly like the native grid, so content replaces them in place.
struct SkeletonVideoGrid: View {
    var history = false

    var body: some View {
        GeometryReader { proxy in
            let size = VideoGridMetrics.itemSize(viewportWidth: proxy.size.width, history: history)
            let columns = max(
                1,
                Int(
                    (proxy.size.width - GlassTheme.contentInset * 2 + VideoGridMetrics.columnSpacing)
                        / (size.width + VideoGridMetrics.columnSpacing)))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(size.width), spacing: VideoGridMetrics.columnSpacing),
                    count: columns),
                alignment: .leading, spacing: 20
            ) {
                ForEach(0..<columns * 3, id: \.self) { _ in
                    SkeletonVideoCard().frame(
                        width: size.width, height: size.height, alignment: .top)
                }
            }
            .padding(.horizontal, GlassTheme.contentInset)
        }
        .shimmering()
        .accessibilityElement()
        .accessibilityLabel("正在加载视频")
    }
}

private struct SkeletonVideoCard: View {
    private let fill = Color.primary.opacity(0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: GlassTheme.artworkRadius).fill(fill)
                .aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(fill).frame(height: 14)
                    Capsule().fill(fill).frame(height: 14).padding(.trailing, 72)
                }
                .frame(height: VideoGridMetrics.titleHeight, alignment: .topLeading)
                HStack(spacing: 6) {
                    Circle().fill(fill)
                        .frame(
                            width: VideoGridMetrics.authorAvatarSize,
                            height: VideoGridMetrics.authorAvatarSize)
                    Capsule().fill(fill).frame(width: 96, height: 11)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// A page-level failure with a single retry, shared by every list.
struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(GlassTheme.iconFont.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message).font(GlassTheme.labelFont).lineLimit(2)
            Spacer(minLength: 12)
            Button("重试", action: retry).buttonStyle(.glass).controlSize(.large)
                .font(GlassTheme.labelFont)
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
        .background(
            .orange.opacity(0.10), in: RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GlassTheme.panelRadius)
                .strokeBorder(.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

/// Title and Done for every sheet, so sheets share one header.
struct SheetHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(GlassTheme.sheetTitleFont).lineLimit(1)
            accessory()
            Spacer(minLength: 12)
            Button("完成") { dismiss() }.buttonStyle(.glass).controlSize(.large)
                .font(GlassTheme.labelFont).keyboardShortcut(.cancelAction)
        }
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
