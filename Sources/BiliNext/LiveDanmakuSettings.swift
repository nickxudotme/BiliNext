import SwiftUI

struct LiveDanmakuSettings: View {
    @AppStorage("danmaku.opacity") private var opacity = 0.85
    @AppStorage("danmaku.font") private var fontSize = 20.0
    @AppStorage("danmaku.area") private var area = 0.5
    @AppStorage("danmaku.speed") private var speed = 1.0
    @AppStorage("danmaku.blocked") private var blocked = ""
    @AppStorage("danmaku.rolling") private var rolling = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画面弹幕").font(GlassTheme.bodyFont.weight(.semibold))
            Toggle("滚动弹幕", isOn: $rolling)
            LabeledContent("不透明度", value: "\(Int(opacity * 100))%")
            Slider(value: $opacity, in: 0.2...1).accessibilityLabel("弹幕不透明度")
            LabeledContent("字号", value: "\(Int(fontSize)) pt")
            Slider(value: $fontSize, in: 14...32, step: 1).accessibilityLabel("弹幕字号")
            LabeledContent("显示区域", value: "\(Int(area * 100))%")
            Slider(value: $area, in: 0.25...1, step: 0.25).accessibilityLabel("弹幕显示区域")
            LabeledContent("弹幕速度", value: String(format: "%g×", speed))
            Slider(value: $speed, in: 0.5...2, step: 0.25).accessibilityLabel("弹幕速度")
            TextField("屏蔽关键词，用逗号分隔", text: $blocked).textFieldStyle(.roundedBorder)
                .accessibilityLabel("弹幕屏蔽关键词")
        }.font(GlassTheme.metadataFont).padding(16).frame(width: 280)
    }
}
