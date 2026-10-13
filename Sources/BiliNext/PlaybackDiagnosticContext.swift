import BiliNextCore
import Foundation

struct PlaybackDiagnosticContext {
    let session: UUID
    let requestedQuality: Int
    let actualQuality: Int
    let codec: String
    let videoBitrate: Int
    let audioBitrate: Int
    let videoHost: String
    let audioHost: String
    let attempt: Int
    let phase: String

    init(
        session: UUID, requestedQuality: Int, source: PlaybackRecovery.Source, attempt: Int,
        phase: String
    ) {
        self.session = session
        self.requestedQuality = requestedQuality
        actualQuality = source.playback.qualityID
        codec = source.playback.videoStream?.codec ?? "MP4"
        videoBitrate = source.playback.videoStream?.bandwidth ?? 0
        audioBitrate = source.playback.audioStream?.bandwidth ?? 0
        videoHost = source.video.host ?? "local"
        audioHost = source.audio?.host ?? "none"
        self.attempt = attempt
        self.phase = phase
    }

    var summary: String {
        "session=\(session.uuidString) phase=\(phase) attempt=\(attempt) quality=\(requestedQuality)/\(actualQuality) codec=\(codec) video-bps=\(videoBitrate) audio-bps=\(audioBitrate) video-cdn=\(videoHost) audio-cdn=\(audioHost)"
    }
}
