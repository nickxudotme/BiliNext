import BiliNextCore
import SwiftUI

struct DownloadRecord: Identifiable, Codable {
    let id: UUID
    let bvid: String
    let cid: Int64
    let title: String
    var episodeID: Int64?
    var state: String
    var progress: Double = 0
    var path: String?
    var error: String?
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadRecord] = []
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var preparation: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: NSKeyValueObservation] = [:]
    private let session: URLSession
    private let store: URL
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0", "Referer": "https://www.bilibili.com/",
        ]
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
        store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliNext/downloads.json")
        if let data = try? Data(contentsOf: store),
            let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        {
            items = records.map { item in
                var item = item
                if ["准备中", "下载中"].contains(item.state) { item.state = "已中断" }
                return item
            }
        }
    }
    func start(video: Video, cid: Int64, quality: Int, api: BilibiliAPI) {
        guard
            !items.contains(where: {
                $0.bvid == video.bvid && $0.cid == cid && ["准备中", "下载中"].contains($0.state)
            })
        else { return }
        let id = UUID()
        items.insert(
            DownloadRecord(
                id: id, bvid: video.bvid, cid: cid, title: video.title, episodeID: video.episodeID,
                state: "准备中"), at: 0)
        save()
        preparation[id] = Task { [self] in
            do {
                let playback = try await api.playback(
                    bvid: video.bvid, cid: cid, quality: quality, episodeID: video.episodeID,
                    preferDASH: false)
                guard !Task.isCancelled else { return }
                let directory = FileManager.default.urls(
                    for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(
                        "BiliNext", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let title = String(video.title.prefix(70)).components(
                    separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")
                ).joined(separator: "_")
                let destination = directory.appendingPathComponent(
                    "\(title)-\(cid)-\(id.uuidString.prefix(6)).mp4")
                let task = session.downloadTask(with: playback.url) {
                    [weak self] temporary, response, error in
                    var failure = error?.localizedDescription
                    if failure == nil {
                        if let temporary, let http = response as? HTTPURLResponse,
                            http.statusCode == 200
                        {
                            do {
                                try FileManager.default.moveItem(at: temporary, to: destination)
                            } catch { failure = error.localizedDescription }
                        } else {
                            failure = "视频下载失败"
                        }
                    }
                    let result = failure
                    Task { @MainActor in
                        guard let self else { return }
                        if let index = self.items.firstIndex(where: { $0.id == id }),
                            self.items[index].state != "已取消"
                        {
                            self.items[index].state = result == nil ? "已完成" : "失败"
                            self.items[index].error = result
                            self.items[index].path = result == nil ? destination.path : nil
                            if result == nil { self.items[index].progress = 1 }
                        }
                        self.tasks[id] = nil
                        self.observers[id] = nil
                        self.preparation[id] = nil
                        self.save()
                    }
                }
                tasks[id] = task
                observers[id] = task.progress.observe(\.fractionCompleted, options: [.new]) {
                    [weak self] progress, _ in
                    let value = progress.fractionCompleted
                    Task { @MainActor in
                        if let self, let index = self.items.firstIndex(where: { $0.id == id }),
                            self.items[index].state == "下载中"
                        {
                            self.items[index].progress = value
                        }
                    }
                }
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].state = "下载中"
                }
                save()
                task.resume()
            } catch {
                if !Task.isCancelled, let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].state = "失败"
                    items[index].error = error.localizedDescription
                    save()
                }
                preparation[id] = nil
            }
        }
    }
    func cancel(_ id: UUID) {
        preparation[id]?.cancel()
        preparation[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        observers[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = "已取消" }
        save()
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: store, options: .atomic)
        } catch {
            // Downloads remain accessible in Finder if the history cannot be saved.
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "下载")
            Text("保存到 下载 / BiliNext · 当前支持单段 MP4，退出应用会中断未完成任务。").font(GlassTheme.metadataFont)
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
                            if item.state == "下载中" {
                                ProgressView(value: item.progress)
                                Button("取消下载") { manager.cancel(item.id) }
                            } else if item.state == "准备中" {
                                ProgressView().controlSize(.small)
                                Button("取消") { manager.cancel(item.id) }
                            } else if let path = item.path {
                                HStack {
                                    Button("打开文件") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }
                                    Button("在 Finder 显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([
                                            URL(fileURLWithPath: path)
                                        ])
                                    }
                                }
                            } else {
                                Button("重新下载") {
                                    manager.start(
                                        video: Video(
                                            bvid: item.bvid, title: item.title,
                                            episodeID: item.episodeID), cid: item.cid, quality: 64,
                                        api: model.api)
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
