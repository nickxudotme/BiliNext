import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func prefetchJoinsRequestsAndConsumesThem() async throws {
    var requests: [PlaybackPrefetch.Key] = []
    let prefetch = PlaybackPrefetch { key in
        requests.append(key)
        try await Task.sleep(for: .milliseconds(20))
        return Playback(
            url: URL(string: "https://upos-sz-mirrorcos.bilivideo.com/\(key.bvid).mp4")!,
            quality: "高清", qualityID: key.quality, qualities: [], videoStream: nil,
            audioStream: nil)
    }
    let key = PlaybackPrefetch.Key(bvid: "BV1111111111", cid: 1, quality: 80)
    // An early request and the open share one fetch.
    prefetch.warm(key)
    #expect(prefetch.age(of: key) != nil)
    let first = try await prefetch.playback(for: key)
    #expect(first.qualityID == 80 && requests.count == 1)
    // Consumed: opening again fetches fresh URLs.
    #expect(prefetch.age(of: key) == nil)
    _ = try await prefetch.playback(for: key)
    #expect(requests.count == 2)

    // Speculative requests are capped while earlier ones are still running.
    for cid in 10..<16 {
        prefetch.speculate(PlaybackPrefetch.Key(bvid: "BV2222222222", cid: Int64(cid), quality: 80))
    }
    try await Task.sleep(for: .milliseconds(5))
    #expect(requests.count == 2 + PlaybackPrefetch.speculativeLimit)
    prefetch.removeAll()
    #expect(
        prefetch.age(of: PlaybackPrefetch.Key(bvid: "BV2222222222", cid: 10, quality: 80)) == nil)
}

@Test func listedPartsArePlayable() {
    #expect(Video(bvid: "BV1", title: "", historyCID: 7, cid: 3).playableCID == 7)
    #expect(Video(bvid: "BV1", title: "", cid: 3).playableCID == 3)
    #expect(Video(bvid: "BV1", title: "").playableCID == nil)
}
