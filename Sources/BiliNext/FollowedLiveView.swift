import SwiftUI

struct FollowedLiveView: View {
    @ObservedObject var lives: FollowedLives
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !lives.rooms.isEmpty {
                Label("关注的直播", systemImage: "dot.radiowaves.left.and.right")
                    .font(GlassTheme.labelFont.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(lives.rooms) { room in
                            Button {
                                model.openLive(room)
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(url: URL(string: room.avatar))
                                        .frame(width: 40, height: 40)
                                        .overlay(alignment: .bottomTrailing) {
                                            Circle().fill(.red).frame(width: 10, height: 10)
                                        }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(room.author).font(
                                            GlassTheme.labelFont.weight(.semibold))
                                        Text(room.title).font(GlassTheme.metadataFont)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 155, alignment: .leading)
                                }.padding(10).contentShape(Rectangle())
                                    .background(
                                        .quaternary.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(InteractionButtonStyle(kind: .row))
                                .accessibilityLabel("\(room.author)正在直播：\(room.title)")
                        }
                    }
                }.scrollIndicators(.hidden)
            } else if let error = lives.error {
                HStack {
                    Text("关注的直播暂时无法加载：\(error)")
                        .font(GlassTheme.metadataFont).foregroundStyle(.secondary).lineLimit(1)
                    Button("重试", action: lives.refresh)
                }
            }
        }.padding(.horizontal, GlassTheme.contentInset)
            .padding(.vertical, lives.rooms.isEmpty && lives.error == nil ? 0 : 12)
    }
}
