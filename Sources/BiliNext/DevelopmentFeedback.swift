import AppKit
import SwiftUI

#if DEBUG
    import SwiftFeedback

    @MainActor
    enum DevelopmentFeedback {
        private static var requestObserver: NSObjectProtocol?

        static func record(
            _ name: String, fields: [String: String], file: String = #fileID, line: UInt = #line
        ) {
            var fields = fields
            fields["source.file"] = file
            fields["source.line"] = String(line)
            FeedbackRecorder.shared.record(name, fields: fields)
        }

        static func configure(model: AppModel) {
            FeedbackCenter.shared.configure { [weak model] in model?.feedbackContext() ?? [:] }
            if requestObserver == nil {
                requestObserver = NotificationCenter.default.addObserver(
                    forName: Notification.Name("BiliNext.developmentRequest"), object: nil,
                    queue: nil
                ) { notification in
                    FeedbackRecorder.shared.record(
                        "api.request", fields: notification.userInfo as? [String: String] ?? [:])
                }
            }
        }
    }

    struct DevelopmentFeedbackCommands: Commands {
        @ObservedObject private var feedback = FeedbackCenter.shared
        var body: some Commands {
            CommandMenu("开发") {
                Button(feedback.isCapturing ? "正在采集现场…" : "反馈当前界面…") { feedback.present() }
                    .keyboardShortcut(feedback.shortcut?.keyboardShortcut)
                    .disabled(feedback.isCapturing)
                Button("打开反馈报告目录") { feedback.openReports() }
            }
        }
    }

    struct DevelopmentFeedbackSettings: View {
        @ObservedObject private var feedback = FeedbackCenter.shared
        var body: some View {
            Section("界面反馈") {
                FeedbackShortcutSettings(shortcut: $feedback.shortcut)
                Button("打开反馈报告目录") { feedback.openReports() }
                Text("从菜单栏「开发」唤起，在原界面标注或录制操作，保存截图、源码位置、运行状态和最近事件。报告仅保存在本机。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    extension AppModel {
        fileprivate func feedbackContext() -> [String: String] {
            let pageModel =
                selected.flatMap { playbackInstances[$0] }
                ?? browseInstances[browsePageID(for: menu)] ?? self
            var values: [String: String] = [
                "workspace.selected": selected ?? "browse",
                "workspace.menu": menu.rawValue,
                "workspace.tabCount": String(tabs.count),
                "workspace.tabs": tabs.map(\.id).joined(separator: ", "),
                "workspace.browsePages": browseInstances.keys.sorted().joined(separator: ", "),
                "workspace.playbackPages": playbackInstances.keys.sorted().joined(separator: ", "),
                "workspace.sidebarPinned": String(sidebarPinned),
                "workspace.miniPlayer": String(miniPlayer),
                "workspace.windowPinned": String(windowPinned),
                "account.loggedIn": String(profile != nil),
                "page.videoID": pageModel.mediaID ?? "",
                "page.partID": pageModel.pageID.map(String.init) ?? "",
                "page.title": pageModel.detail?.video.title ?? "",
                "page.videoLoading": String(pageModel.videoLoading),
                "page.browseLoading": String(pageModel.loading),
                "page.browseCount": String(pageModel.videos.count),
                "page.browsePage": String(pageModel.page),
                "page.hasMore": String(pageModel.hasMore),
                "page.browseError": pageModel.browseError ?? "",
                "page.playerError": pageModel.playerError ?? "",
                "page.toast": pageModel.toast ?? "",
                "playback.time": String(pageModel.time),
                "playback.duration": String(pageModel.duration),
                "playback.playing": String(pageModel.playing),
                "playback.buffering": String(pageModel.buffering),
                "playback.rate": String(pageModel.playbackRate),
                "playback.quality": pageModel.quality,
                "playback.qualityID": String(pageModel.qualityID),
                "playback.codec": pageModel.playbackCodec,
                "playback.awaitingLoad": String(pageModel.awaitingMPVLoad),
                "playback.theater": String(pageModel.theater),
                "playback.officialCore": String(pageModel.officialCore),
                "subtitles.primary": pageModel.trackID,
                "subtitles.secondary": pageModel.secondaryTrackID,
                "subtitles.cueCount": String(pageModel.cues.count),
                "subtitles.secondaryCueCount": String(pageModel.secondaryCues.count),
                "subtitles.loading": String(pageModel.subtitleLoading),
                "subtitles.error": pageModel.subtitleError ?? "",
                "build.commit": Bundle.main.object(forInfoDictionaryKey: "FeedbackGitCommit")
                    as? String ?? "unknown",
                "build.dirty": Bundle.main.object(forInfoDictionaryKey: "FeedbackGitDirty")
                    as? String ?? "unknown",
                "build.configuration": "debug",
            ]
            if let mpv = pageModel.mpv {
                values["mpv.loaded"] = String(mpv.loaded)
                values["mpv.failure"] = mpv.failure ?? ""
                values["mpv.prematureEnd"] = String(mpv.prematureEnd)
                if let cache = mpv.cacheSnapshot {
                    values["mpv.cache.eof"] = String(cache.eof)
                    values["mpv.cache.end"] = cache.end.map { String($0) } ?? "unavailable"
                    values["mpv.cache.videoEnd"] =
                        cache.videoEnd.map { String($0) } ?? "unavailable"
                    values["mpv.cache.audioEnd"] =
                        cache.audioEnd.map { String($0) } ?? "unavailable"
                }
                values["mpv.context"] = mpv.diagnosticContext?.summary ?? ""
                for property in [
                    "time-pos", "duration", "volume", "speed", "video-params/w", "video-params/h",
                    "estimated-vf-fps", "decoder-frame-drop-count", "frame-drop-count",
                    "demuxer-cache-duration", "cache-speed", "display-fps", "avsync",
                ] {
                    values["mpv." + property] = String(mpv.number(property))
                }
                for property in ["pause", "paused-for-cache", "eof-reached", "mute"] {
                    values["mpv." + property] = String(mpv.flag(property))
                }
            }
            return values
        }
    }
#endif

extension View {
    @ViewBuilder
    func developmentFeedbackTarget(
        _ id: String, label: String? = nil, isActive: Bool = true,
        file: String = #fileID, line: UInt = #line
    ) -> some View {
        #if DEBUG
            feedbackTarget(id, label: label, isActive: isActive, file: file, line: line)
        #else
            self
        #endif
    }
}
