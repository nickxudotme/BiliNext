import SwiftUI

struct SmartSubtitleSettings: View {
    @ObservedObject var model: SmartSubtitleModel
    var automaticDetectionSuspended = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("画面软字幕", isOn: Binding(get: { model.visible }, set: { model.setVisible($0) }))
            Toggle("自动处理重复字幕", isOn: $model.enabled)
            Toggle("有可用字幕时自动开启", isOn: $model.autoShow)
            Picker("语言不同", selection: $model.differentLanguage) {
                Text("保留软字幕").tag("keep")
                Text("先询问").tag("ask")
                Text("隐藏软字幕").tag("hide")
            }
            if model.hasChannel {
                Picker("此 UP 主", selection: $model.channelRule) { rules }
            }
            Picker("此视频 / 分 P", selection: $model.videoRule) { rules }
            HStack(alignment: .top) {
                if model.checking { ProgressView().controlSize(.mini) }
                Text(automaticDetectionSuspended ? "双语模式：自动检测已暂停" : model.status)
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            if model.needsDecision {
                HStack {
                    Button("保留") { model.resolveLanguage(keep: true) }
                    Button("隐藏") { model.resolveLanguage(keep: false) }
                }
            }
            if !model.visible && model.videoRule == "auto" {
                Button("记住此视频的隐藏结果") { model.videoRule = "hide" }
            }
            HStack {
                Button("重新检测") { model.redetect() }
                Button("恢复软字幕") { model.setVisible(true) }
            }
            Text("每 4 秒最多取样一次，连续 3 条不同字幕确认后处理。识别仅在本机进行，Transcript 保留完整文字。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var rules: some View {
        Text("跟随自动设置").tag("auto")
        Text("始终保留").tag("show")
        Text("始终隐藏").tag("hide")
    }
}
