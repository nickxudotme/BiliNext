import BiliNextCore
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "下载")
            Text("支持分轨合并、暂停和续传。退出后保留进度；缓存文件与导出的视频分别保存。").font(GlassTheme.metadataFont)
                .foregroundStyle(
                    .secondary)
            if manager.items.isEmpty {
                ContentUnavailableView(
                    "还没有下载", systemImage: "arrow.down.circle",
                    description: Text("在播放页点击「缓存」，视频会保存到这里。"))
            }
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(manager.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title).font(GlassTheme.bodyFont).lineSpacing(3).lineLimit(
                                    2)
                                Spacer()
                                Text(item.state).font(GlassTheme.metadataFont).foregroundStyle(
                                    .secondary)
                            }
                            if ["下载中", "合并中", "保存中"].contains(item.state) {
                                ProgressView(value: item.progress)
                                Button("暂停") { manager.pause(item.id) }
                            } else if ["准备中", "排队中"].contains(item.state) {
                                ProgressView().controlSize(.small)
                                Button("取消") { manager.cancel(item.id) }
                            } else if let path = item.path {
                                HStack {
                                    Button("离线播放") {
                                        model.openLocalMedia(
                                            URL(fileURLWithPath: path), title: item.title)
                                        dismiss()
                                    }.accessibilityIdentifier("download.play.\(item.id.uuidString)")
                                    Button("打开文件") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }
                                    if item.cached == true {
                                        Button("删除缓存", role: .destructive) {
                                            manager.deleteCache(item.id)
                                        }
                                    }
                                    Button("在 Finder 显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([
                                            URL(fileURLWithPath: path)
                                        ])
                                    }
                                }
                            } else {
                                HStack {
                                    Button("继续下载") { manager.resume(item.id, api: model.api) }
                                    Button("移除任务") { manager.remove(item.id) }
                                }
                            }
                            if let error = item.error {
                                Text(error).font(GlassTheme.metadataFont).foregroundStyle(
                                    .secondary)
                            }
                        }.controlSize(.large).font(GlassTheme.labelFont).padding(14).background(
                            .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(24).frame(width: 600, height: 480)
    }
}
