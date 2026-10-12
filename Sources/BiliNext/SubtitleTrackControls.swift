import SwiftUI

struct SubtitleTrackControls: View {
    @ObservedObject var model: AppModel
    @AppStorage("player.subtitle.removeLineBreaks") private var removeLineBreaks = false

    var body: some View {
        if !model.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "主字幕",
                    selection: Binding(get: { model.trackID }, set: { model.selectTrack($0) })
                ) {
                    ForEach(model.tracks) { track in Text(track.language).tag(track.id) }
                }
                if model.tracks.count > 1 {
                    Picker(
                        "第二字幕",
                        selection: Binding(
                            get: { model.secondaryTrackID }, set: { model.selectSecondaryTrack($0) }
                        )
                    ) {
                        Text("关闭（单语）").tag("")
                        ForEach(model.tracks.filter { $0.id != model.trackID }) { track in
                            Text(track.language).tag(track.id)
                        }
                    }
                }
                Toggle("去掉字幕内换行", isOn: $removeLineBreaks)
                    .help("只去掉画面字幕的强制换行；宽度不足时仍自然换行，字幕脚本保留原文。")
                if !model.secondaryTrackID.isEmpty {
                    Text("画面同时显示两条字幕；脚本阅读使用主字幕。双语模式暂停自动去重，手动字幕开关仍有效。")
                        .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    if model.secondarySubtitleLoading {
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text("正在加载第二字幕…").font(GlassTheme.metadataFont)
                        }
                    } else if let error = model.secondarySubtitleError {
                        Text("第二字幕加载失败：\(error)").font(GlassTheme.metadataFont)
                            .foregroundStyle(.secondary)
                        Button("重试第二字幕") { model.selectSecondaryTrack(model.secondaryTrackID) }
                    } else if model.secondaryCues.isEmpty {
                        Text("此字幕轨没有可用内容，可选择其他字幕。")
                            .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    }
                }
            }.font(GlassTheme.labelFont).controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
