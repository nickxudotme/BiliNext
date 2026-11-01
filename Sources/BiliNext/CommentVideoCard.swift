import BiliNextCore
import SwiftUI

private struct CommentResolverKey: EnvironmentKey {
    static let defaultValue: CommentVideoResolver? = nil
}
extension EnvironmentValues {
    var commentVideoResolver: CommentVideoResolver? {
        get { self[CommentResolverKey.self] }
        set { self[CommentResolverKey.self] = newValue }
    }
}

struct CommentVideoCards: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            ForEach(CommentVideoLinks.parse(text), id: \.self) { url in
                CommentVideoCard(url: url)
            }
        }
    }
}

private struct CommentVideoCard: View {
    let url: URL
    @Environment(\.commentVideoResolver) private var resolver
    @Environment(\.commentImagePlaybackActive) private var active
    @Environment(\.openURL) private var openURL
    @State private var video: Video?
    @State private var loading = true
    @State private var visible = false
    var body: some View {
        Button {
            openURL(video.map { CommentLinks.video($0.bvid) } ?? url)
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: video?.cover) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary).overlay { Image(systemName: "play.rectangle") }
                }
                .frame(width: 84, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(video?.title ?? (loading ? "正在读取视频…" : "打开视频链接")).lineLimit(2)
                    if let video {
                        Text(video.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(GlassTheme.metadataFont).padding(8).background(
                .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help("打开视频 · ⌘ 点击在后台打开")
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .task(id: active && visible ? url : nil) {
                guard active, visible, video == nil, let resolver else { return }
                let result = await resolver.resolve(url)
                guard !Task.isCancelled else { return }
                video = result
                loading = false
            }
    }
}
