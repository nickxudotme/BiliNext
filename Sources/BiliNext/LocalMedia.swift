import AppKit
import BiliNextCore
import CryptoKit
import UniformTypeIdentifiers

/// A local source is distinct from a Bilibili identity. Bookmarks can follow moved files.
struct LocalMedia: Codable, Equatable {
    let url: URL
    let bookmark: Data?

    init(url: URL) throws {
        guard url.isFileURL else { throw MPVError(message: "请选择本地视频文件") }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        bookmark = try? self.url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    var id: String {
        "local:"
            + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }
            .joined()
    }
    func resolve() throws -> URL {
        var stale = false
        let resolved =
            bookmark.flatMap {
                try? URL(
                    resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            } ?? url
        guard resolved.isFileURL, FileManager.default.isReadableFile(atPath: resolved.path),
            (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw MPVError(message: "找不到本地视频，文件可能已移动或被删除。请重新选择文件。") }
        return resolved
    }
}

extension AppModel {
    var localMedia: LocalMedia? {
        tabs.first(where: { $0.id == selected || $0.id == mediaID })?.localMedia
    }
    var isLocalMedia: Bool { localMedia != nil }

    func openLocalMedia(_ url: URL, title: String? = nil, autoplay: Bool = true) {
        if let tabOwner {
            tabOwner.openLocalMedia(url, title: title, autoplay: autoplay)
            return
        }
        do {
            let source = try LocalMedia(url: url)
            _ = try source.resolve()
            let existing = tabs.first { tab in
                guard let media = tab.localMedia else { return false }
                return media.id == source.id || (try? media.resolve()) == source.url
            }
            let id = existing?.id ?? source.id
            if existing == nil {
                tabs.append(
                    SessionTab(
                        video: Video(
                            bvid: id, title: title ?? url.deletingPathExtension().lastPathComponent,
                            author: "本地视频"), localMedia: source))
            }
            activate(id, autoplay: autoplay)
        } catch { toast = error.localizedDescription }
    }

    func chooseLocalMedia(replacing id: String? = nil) {
        if let tabOwner {
            tabOwner.chooseLocalMedia(replacing: id)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes =
            [.movie, .video]
            + ["mkv", "webm", "flv", "avi", "ts", "m2ts"].compactMap {
                UTType(filenameExtension: $0)
            }
        panel.allowsMultipleSelection = id == nil
        panel.canChooseDirectories = false
        panel.prompt = "打开视频"
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            if let id, let url = panel.url, let index = tabs.firstIndex(where: { $0.id == id }) {
                do {
                    let source = try LocalMedia(url: url)
                    _ = try source.resolve()
                    saveSession()
                    releasePlaybackTab(id)
                    tabs[index].localMedia = source
                    tabs[index].video = Video(
                        bvid: id, title: url.deletingPathExtension().lastPathComponent,
                        author: "本地视频")
                    tabs[index].position = 0
                    activate(id, force: true, autoplay: false)
                } catch { toast = error.localizedDescription }
            } else {
                for url in panel.urls { openLocalMedia(url) }
            }
        }
    }

    func activateLocalMedia(_ id: String, force: Bool, autoplay: Bool) {
        selected = id
        if mediaID == id && !force {
            if autoplay {
                playbackIntent = true
                startBufferedPlayback()
            }
            return
        }
        saveSession()
        stopMedia()
        selected = id
        mediaID = id
        detail = nil
        pageID = nil
        qualities = []
        tracks = []
        cues = []
        trackID = ""
        highEnergy = nil
        videoShots = nil
        viewPoints = []
        relationVideo = nil
        relationLoaded = false
        officialCore = false
        subtitleLoading = false
        playerError = nil
        playbackIntent = autoplay && playbackTabActive
        let position = tabs.first(where: { $0.id == id })?.position ?? 0
        recoveryPosition = position
        updatePlayback(time: position, duration: 0, playing: false, buffering: false)
        do {
            guard let source = localMedia else { throw MPVError(message: "本地文件记录已失效") }
            let url = try source.resolve()
            let core = try ensureMPV()
            core.speed = playbackRate
            awaitingMPVLoad = true
            videoLoading = true
            try core.loadFile(url, position: position, autoplay: playbackIntent)
        } catch {
            awaitingMPVLoad = false
            videoLoading = false
            playerError = error.localizedDescription
        }
    }
}
