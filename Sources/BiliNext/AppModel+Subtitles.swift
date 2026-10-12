import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Subtitles

    func selectTrack(_ id: String) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        subtitleTask?.cancel()
        let generation = UUID()
        subtitleGeneration = generation
        trackID = id
        smartSubtitles.configure(
            video: mediaID, cid: pageID, owner: detail?.video.ownerID, track: track.language)
        cues = []
        subtitleError = nil
        subtitleLoading = true
        subtitleTask = Task {
            do {
                let result = try await api.subtitles(track)
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                cues = result
            } catch {
                guard !Task.isCancelled, generation == subtitleGeneration else { return }
                subtitleError = error.localizedDescription
            }
            subtitleLoading = false
        }
    }

}
