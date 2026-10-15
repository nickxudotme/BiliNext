import AVKit
import AppKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Subtitles

    var canCopyTranscript: Bool {
        !subtitleLoading && subtitleError == nil && cues.contains { !$0.text.isEmpty }
    }

    /// Copies the complete primary track, independently of the transcript's display filters.
    func copyTranscript() {
        guard canCopyTranscript else { return }
        let text = cues.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            toast = "已复制全部字幕（\(cues.count) 条）"
        } else {
            toast = "未能写入剪贴板，请重试"
        }
    }

    func selectTrack(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        subtitleTask?.cancel()
        let generation = UUID()
        subtitleGeneration = generation
        if id == secondaryTrackID { resetSecondarySubtitles() }
        trackID = id
        smartSubtitles.configure(
            video: mediaID, cid: pageID, owner: detail?.video.ownerID, track: track.language)
        if !secondaryTrackID.isEmpty { smartSubtitles.setVisible(true) }
        cues = []
        subtitleError = nil
        subtitleLoading = true
        subtitleTask = Task {
            do {
                let result = try await subtitleLoader(track)
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                cues = result
            } catch {
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                subtitleError = error.localizedDescription
            }
            subtitleLoading = false
        }
    }

    func selectSecondaryTrack(_ id: String) {
        guard id.isEmpty || (id != trackID && tracks.contains(where: { $0.id == id })) else {
            return
        }
        resetSecondarySubtitles()
        guard let track = tracks.first(where: { $0.id == id }) else {
            smartSubtitles.redetect()
            return
        }
        secondaryTrackID = id
        secondarySubtitleLoading = true
        smartSubtitles.setVisible(true)
        let generation = secondarySubtitleGeneration
        secondarySubtitleTask = Task {
            do {
                let result = try await subtitleLoader(track)
                guard !Task.isCancelled, generation == secondarySubtitleGeneration else { return }
                secondaryCues = result
            } catch {
                guard !Task.isCancelled, generation == secondarySubtitleGeneration else { return }
                secondarySubtitleError = error.localizedDescription
            }
            secondarySubtitleLoading = false
            secondarySubtitleTask = nil
        }
    }

    func resetSecondarySubtitles() {
        secondarySubtitleTask?.cancel()
        secondarySubtitleTask = nil
        secondarySubtitleGeneration = UUID()
        secondaryTrackID = ""
        secondaryCues = []
        secondarySubtitleLoading = false
        secondarySubtitleError = nil
    }
}
