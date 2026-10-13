import BiliNextCore
import SwiftUI

struct LiveActivityCard: View {
    let room: LiveRoom
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.openLive(room)
        } label: {
            HStack(spacing: 14) {
                ThumbnailView(url: URL(string: room.cover), pixels: 640) {
                    Color.gray.opacity(0.2)
                }.frame(width: 220, height: 124).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        room.isLive ? "直播中" : "直播已结束", systemImage: "dot.radiowaves.left.and.right"
                    )
                    .font(GlassTheme.labelFont.weight(.semibold))
                    .foregroundStyle(room.isLive ? .red : .secondary)
                    Text(room.title).font(GlassTheme.bodyFont).lineLimit(2)
                    Text(room.areaName).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(InteractionButtonStyle(kind: .row))
            .help("在 BiliNext 打开直播")
    }
}
