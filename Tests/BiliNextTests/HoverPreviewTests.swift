import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func hoverPreviewDebouncesAndCancelsWithoutOpeningTabs() async throws {
    var requests: [String] = []
    let api = BilibiliAPI(restoreSession: false)
    let preview = HoverPreview(api: api) { video in
        requests.append(video.id)
        throw URLError(.notConnectedToInternet)
    }
    let first = Video(bvid: "BV1111111111", title: "一")
    let second = Video(bvid: "BV2222222222", title: "二")
    preview.request(first)
    preview.stop(ifMatching: first.id)
    try await Task.sleep(for: .milliseconds(500))
    #expect(requests.isEmpty)
    preview.request(first)
    preview.request(second)
    preview.stop(ifMatching: first.id)
    #expect(preview.activeID == second.id)
    try await Task.sleep(for: .milliseconds(600))
    #expect(requests == [second.id])
    #expect(preview.activeID == nil && !preview.ready)
    #expect(preview.player.isMuted && preview.player.volume == 0)
    #expect(preview.player.currentItem == nil)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_DASH_TEST"] == "1"))
func mutedHoverPreviewPlaysAndReleasesMedia() async throws {
    let api = BilibiliAPI(credentialStorage: .developmentFile)
    let preview = HoverPreview(api: api)
    defer { preview.stop() }
    preview.request(Video(bvid: "BV1dyaZ6gEwU", title: "预览验证"))
    for _ in 0..<200 {
        if preview.player.currentTime().seconds > 1 { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    #expect(preview.ready)
    #expect(preview.player.currentTime().seconds > 1)
    #expect(preview.player.isMuted && preview.player.volume == 0)
    preview.stop()
    #expect(preview.player.currentItem == nil && preview.activeID == nil)
    print("Hover preview: actual muted playback passed, stop released media")
}
