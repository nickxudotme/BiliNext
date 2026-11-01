import SwiftUI

struct PlaybackInspector: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("播放信息", systemImage: "waveform.path.ecg").font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark", action: close).labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let player = model.mpv {
                        VStack(spacing: 10) {
                            metric("状态", model.buffering ? "缓冲中" : player.playing ? "播放中" : "已暂停")
                            metric(
                                "分辨率",
                                "\(integer(player.number("video-params/w"))) × \(integer(player.number("video-params/h")))"
                            )
                            metric("视频编码", player.text("video-codec"))
                            metric("硬件解码", player.text("hwdec-current"))
                            metric(
                                "视频帧率", String(format: "%.2f fps", player.number("container-fps")))
                            metric(
                                "前向缓冲",
                                String(format: "%.1f 秒", player.number("demuxer-cache-duration")))
                            metric(
                                "下载速度",
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(integer(player.number("cache-speed"))),
                                    countStyle: .file) + "/s")
                            metric(
                                "解码 / 输出丢帧",
                                "\(integer(player.number("decoder-frame-drop-count"))) / \(integer(player.number("frame-drop-count")))"
                            )
                            if let context = player.diagnosticContext {
                                Divider()
                                metric("视频 CDN", context.videoHost)
                                metric("音频 CDN", context.audioHost)
                                metric("视频码率", "\(context.videoBitrate / 1000) kbps")
                                metric("恢复尝试", "\(context.attempt)")
                            }
                            Text("下载速度为播放器当前读取速度，缓冲充足时可能为零。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(copied ? "已复制诊断" : "复制播放诊断") {
                guard let player = model.mpv else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(player.diagnosticSummary, forType: .string)
                copied = true
            }.buttonStyle(.glass)
        }
        .padding(16).frame(width: 330, height: 440)
        .floatingGlassPanel()
        .accessibilityElement(children: .contain)
    }

    private func integer(_ value: Double) -> Int {
        value.isFinite && value >= 0 && value < Double(Int.max) ? Int(value) : 0
    }

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "—" : value).monospacedDigit().textSelection(.enabled)
        }
        .font(.caption)
    }
}
