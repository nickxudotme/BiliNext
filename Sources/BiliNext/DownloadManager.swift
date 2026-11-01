import BiliNextCore
import Foundation

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
    var quality: Int? = nil
    var accountID: Int64? = nil
    var cached: Bool? = nil
    var destination: String? = nil
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var items: [DownloadRecord] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: BilibiliAPI] = [:]
    private var generations: [UUID: UUID] = [:]
    private let store: URL
    private let workDirectory: URL
    let cacheDirectory: URL

    init(store: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ].appendingPathComponent("BiliNext")
        self.store = store ?? root.appendingPathComponent("downloads.json")
        workDirectory = self.store.deletingLastPathComponent().appendingPathComponent(
            "DownloadTransfers")
        cacheDirectory = self.store.deletingLastPathComponent().appendingPathComponent(
            "OfflineVideos")
        if let data = try? Data(contentsOf: self.store),
            let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        {
            items = records.map { record in
                var record = record
                if ["准备中", "排队中", "下载中", "合并中", "保存中"].contains(record.state) {
                    record.state = "已暂停"
                }
                return record
            }
        }
    }
    func start(
        video: Video, cid: Int64, quality: Int, api: BilibiliAPI, cached: Bool = false,
        directory: URL? = nil
    ) {
        guard
            !items.contains(where: {
                $0.bvid == video.bvid && $0.cid == cid
                    && ["准备中", "排队中", "下载中", "合并中", "保存中"].contains($0.state)
            })
        else { return }
        let id = UUID()
        let root =
            directory
            ?? (cached
                ? cacheDirectory
                : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BiliNext"))
        let title = String(video.title.prefix(70)).components(
            separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")
        ).joined(separator: "_")
        let destination = root.appendingPathComponent(
            "\(title)-\(cid)-\(id.uuidString.prefix(6)).mp4")
        items.insert(
            DownloadRecord(
                id: id, bvid: video.bvid, cid: cid, title: video.title, episodeID: video.episodeID,
                state: "排队中", quality: quality, cached: cached, destination: destination.path),
            at: 0)
        clients[id] = api
        guard save() else { return }
        schedule()
    }
    func resume(_ id: UUID, api: BilibiliAPI) {
        guard tasks[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
            items[index].path == nil
        else { return }
        items[index].state = "排队中"
        items[index].error = nil
        clients[id] = api
        guard save() else { return }
        schedule()
    }
    func pause(_ id: UUID) {
        generations[id] = UUID()
        tasks[id]?.cancel()
        if let index = items.firstIndex(where: { $0.id == id }), items[index].path == nil {
            items[index].state = "已暂停"
            items[index].error = nil
        }
        save()
    }
    func cancel(_ id: UUID) { pause(id) }
    func pauseAll() {
        for item in items where ["准备中", "排队中", "下载中", "合并中", "保存中"].contains(item.state) {
            pause(item.id)
        }
    }
    func remove(_ id: UUID) {
        guard tasks[id] == nil else {
            pause(id)
            return
        }
        items.removeAll { $0.id == id }
        clients[id] = nil
        generations[id] = nil
        if save() {
            try? FileManager.default.removeItem(
                at: workDirectory.appendingPathComponent(id.uuidString))
        }
    }
    func deleteCache(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.cached == true,
            let path = item.path,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(
                cacheDirectory.resolvingSymlinksInPath().path + "/")
        else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            remove(id)
        } catch {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].error = error.localizedDescription
            }
        }
    }
    private func schedule() {
        for item in items where item.state == "排队中" && tasks[item.id] == nil {
            guard tasks.count < 2 else { break }
            guard let api = clients[item.id] else { continue }
            let generation = UUID()
            generations[item.id] = generation
            tasks[item.id] = Task { [weak self] in
                guard let self else { return }
                await run(item, api: api, generation: generation)
                tasks[item.id] = nil
                schedule()
            }
        }
    }
    private func run(_ initial: DownloadRecord, api: BilibiliAPI, generation: UUID) async {
        let id = initial.id
        defer { if generations[id] == generation { generations[id] = nil } }
        let folder = workDirectory.appendingPathComponent(id.uuidString)
        let output = folder.appendingPathComponent("prepared.mp4")
        do {
            let cookies = await api.officialPlayerCookies()
            let account = Int64(cookies.first { $0.name == "DedeUserID" }?.value ?? "")
            if let expected = initial.accountID, expected != account {
                throw MPVError(message: "请切回创建下载任务的账号后继续")
            }
            guard let index = items.firstIndex(where: { $0.id == id }),
                generations[id] == generation
            else { return }
            items[index].accountID = account
            items[index].state = "准备中"
            items[index].error = nil
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination: URL
            if let path = initial.destination {
                destination = URL(fileURLWithPath: path)
            } else {
                destination = FileManager.default.urls(
                    for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(
                        "BiliNext/\(initial.cid)-\(id.uuidString).mp4")
                items[index].destination = destination.path
            }
            guard save() else { return }
            var checkpoint = try await Task.detached(priority: .utility) {
                try DownloadAssembler.restore(output)
            }.value
            if checkpoint == nil {
                let playback = try await api.playback(
                    bvid: initial.bvid, cid: initial.cid, quality: initial.quality ?? 80,
                    episodeID: initial.episodeID, allowAV1: false, codecs: [.hevc, .avc])
                try Task.checkCancellation()
                let current = await api.officialPlayerCookies().first { $0.name == "DedeUserID" }?
                    .value
                guard account == current.flatMap(Int64.init) else {
                    throw MPVError(message: "账号已切换，下载已保留")
                }
                update(id, generation: generation, state: "下载中", progress: initial.progress)
                let transfer = ResumableMediaDownload()
                let hasAudio = playback.audioStream != nil
                let video = try await transfer.download(
                    urls: playback.videoStream?.urls ?? [playback.url],
                    codec: playback.videoStream?.codec ?? "mp4",
                    indexEnd: playback.videoStream?.index.upperBound ?? 65_535,
                    directory: folder.appendingPathComponent("video")
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.update(
                            id, generation: generation, state: "下载中",
                            progress: value * (hasAudio ? 0.65 : 0.9))
                    }
                }
                var audio: URL?
                if let stream = playback.audioStream {
                    audio = try await transfer.download(
                        urls: stream.urls, codec: stream.codec, indexEnd: stream.index.upperBound,
                        directory: folder.appendingPathComponent("audio")
                    ) { [weak self] value in
                        Task { @MainActor in
                            self?.update(
                                id, generation: generation, state: "下载中",
                                progress: 0.65 + value * 0.25)
                        }
                    }
                }
                try Task.checkCancellation()
                update(id, generation: generation, state: "合并中", progress: 0.92)
                checkpoint = try await DownloadAssembler.prepare(
                    video: video, audio: audio, output: output)
            }
            try Task.checkCancellation()
            guard let checkpoint else { throw MPVError(message: "下载检查点无效") }
            update(id, generation: generation, state: "保存中", progress: 0.98)
            let target = try await Task.detached(priority: .utility) {
                try DownloadAssembler.publish(
                    output, destination: destination, checkpoint: checkpoint)
            }.value
            guard generations[id] == generation,
                let index = items.firstIndex(where: { $0.id == id })
            else { return }
            items[index].state = "已完成"
            items[index].path = target.path
            items[index].progress = 1
            items[index].error = nil
            if save() { try? FileManager.default.removeItem(at: folder) }
        } catch {
            guard generations[id] == generation,
                let index = items.firstIndex(where: { $0.id == id })
            else { return }
            items[index].state = Task.isCancelled ? "已暂停" : "失败"
            items[index].error = Task.isCancelled ? nil : error.localizedDescription
            save()
        }
    }
    private func update(_ id: UUID, generation: UUID, state: String, progress: Double) {
        guard generations[id] == generation, let index = items.firstIndex(where: { $0.id == id })
        else { return }
        items[index].state = state
        items[index].progress = progress
    }
    @discardableResult private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: store, options: .atomic)
            return true
        } catch {
            for index in items.indices {
                if items[index].state == "排队中" || items[index].state == "准备中" {
                    items[index].state = "失败"
                }
                items[index].error = "无法保存下载记录：" + error.localizedDescription
            }
            return false
        }
    }
}
