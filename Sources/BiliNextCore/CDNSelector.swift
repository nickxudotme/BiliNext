import Foundation

public final class CDNSelector: Sendable {
    private let transport: MediaRangeTransport
    public init(transport: MediaRangeTransport = MediaRangeTransport()) {
        self.transport = transport
    }
    deinit { transport.close() }
    public func select(_ playback: Playback) async -> Playback {
        guard let stream = playback.videoStream else { return playback }
        let candidates = Array(stream.urls.filter(MediaURLPolicy.allows).prefix(3))
        guard candidates.count > 1 else { return playback }
        let winner = await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
            for url in candidates {
                group.addTask { [transport] in
                    do {
                        let response = try await transport.read(
                            url, start: 0, length: 1024, timeout: 1.5)
                        try Task.checkCancellation()
                        return response.data.isEmpty ? nil : url
                    } catch { return nil }
                }
            }
            defer { group.cancelAll() }
            while let result = await group.next() { if let result { return result } }
            return nil
        }
        guard !Task.isCancelled, let winner else { return playback }
        let video = PlaybackStream(
            urls: [winner] + stream.urls.filter { $0 != winner }, codec: stream.codec,
            bandwidth: stream.bandwidth, initialization: stream.initialization, index: stream.index)
        let audio = playback.audioStream.map { stream in
            let urls =
                stream.urls.filter { $0.host == winner.host }
                + stream.urls.filter { $0.host != winner.host }
            return PlaybackStream(
                urls: urls, codec: stream.codec, bandwidth: stream.bandwidth,
                initialization: stream.initialization, index: stream.index)
        }
        return Playback(
            url: winner, quality: playback.quality, qualityID: playback.qualityID,
            qualities: playback.qualities, videoStream: video, audioStream: audio)
    }
}
