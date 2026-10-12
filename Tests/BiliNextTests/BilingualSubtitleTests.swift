import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@Test func bilingualLinesUseIndependentTimingsAndKeepOverlapsAndGaps() {
    let primary = [
        Cue(id: 0, start: 0, end: 2, text: "你好"), Cue(id: 1, start: 1, end: 3, text: "世界"),
    ]
    let secondary = [
        Cue(id: 0, start: 0.5, end: 1.5, text: "Hello"),
        Cue(id: 1, start: 2.5, end: 4, text: "World"),
    ]
    #expect(SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 0) == ["你好"])
    #expect(
        SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 1) == [
            "你好\n世界", "Hello",
        ])
    #expect(SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 2) == ["世界"])
    #expect(SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 3) == ["World"])
    #expect(SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 4).isEmpty)
}

@MainActor
@Test func secondarySubtitleLoadingIsIndependentAndLateResultsCannotReturn() async throws {
    let primary = SubtitleTrack(language: "中文", url: URL(string: "https://example.com/zh")!)
    let slow = SubtitleTrack(language: "英语", url: URL(string: "https://example.com/en")!)
    let fast = SubtitleTrack(language: "日语", url: URL(string: "https://example.com/ja")!)
    let primaryCues = [Cue(id: 0, start: 0, end: 3, text: "主字幕")]
    let suite = "BilingualSubtitleTests.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(
        managesPlaybackTabs: false, api: BilibiliAPI(restoreSession: false),
        subtitleLoader: { track in
            // Deliberately ignore cancellation to verify generation checks, not just Task.cancel().
            try? await Task.sleep(for: .milliseconds(track.id == slow.id ? 100 : 10))
            return [Cue(id: 0, start: 0, end: 3, text: track.language)]
        }, subtitlePreferences: preferences)
    model.tracks = [primary, slow, fast]
    model.trackID = primary.id
    model.cues = primaryCues
    model.selectSecondaryTrack(slow.id)
    #expect(model.secondarySubtitleLoading)
    #expect(model.cues == primaryCues)
    let oldTask = try #require(model.secondarySubtitleTask)
    model.selectSecondaryTrack(fast.id)
    await model.secondarySubtitleTask?.value
    await oldTask.value
    #expect(model.secondaryTrackID == fast.id)
    #expect(model.secondaryCues.first?.text == "日语")
    #expect(model.cues == primaryCues)
    model.selectSecondaryTrack(primary.id)
    #expect(model.secondaryTrackID == fast.id)  // Cannot select the primary twice.
    model.selectTrack(fast.id)
    await model.subtitleTask?.value
    #expect(model.secondaryTrackID.isEmpty)
    #expect(model.cues.first?.text == "日语")
    model.selectSecondaryTrack(slow.id)
    let pending = try #require(model.secondarySubtitleTask)
    model.resetSecondarySubtitles()
    await pending.value
    #expect(model.secondaryTrackID.isEmpty && model.secondaryCues.isEmpty)
    #expect(!model.secondarySubtitleLoading && model.secondarySubtitleError == nil)
}

@MainActor
@Test func secondSubtitleFailureKeepsPrimaryAndCanRetryOrDisable() async throws {
    let primary = SubtitleTrack(language: "中文", url: URL(string: "https://example.com/zh")!)
    let secondary = SubtitleTrack(language: "英语", url: URL(string: "https://example.com/en")!)
    var failed = true
    let suite = "BilingualSubtitleTests.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(
        managesPlaybackTabs: false, api: BilibiliAPI(restoreSession: false),
        subtitleLoader: { _ in
            if failed { throw URLError(.notConnectedToInternet) }
            return [Cue(id: 0, start: 0, end: 3, text: "Hello")]
        }, subtitlePreferences: preferences)
    model.tracks = [primary, secondary]
    model.trackID = primary.id
    model.cues = [Cue(id: 0, start: 0, end: 3, text: "你好")]
    model.selectSecondaryTrack(secondary.id)
    await model.secondarySubtitleTask?.value
    #expect(model.secondarySubtitleError != nil)
    #expect(model.subtitleError == nil && model.cues.first?.text == "你好")
    failed = false
    model.selectSecondaryTrack(secondary.id)
    await model.secondarySubtitleTask?.value
    #expect(model.secondarySubtitleError == nil && model.secondaryCues.first?.text == "Hello")
    model.selectSecondaryTrack("")
    #expect(model.secondaryTrackID.isEmpty && model.secondaryCues.isEmpty)
    #expect(model.cues.first?.text == "你好")
}

@Test func subtitleLineBreaksArePreservedByDefaultAndOptionalReflowKeepsSource() {
    let primary = [Cue(id: 0, start: 0, end: 2, text: "另一个赢家也在庆祝胜利：\n赌博业。")]
    let secondary = [
        Cue(
            id: 0, start: 0, end: 2,
            text: "there was another clear winner:\r\nthe gambling industry.")
    ]
    #expect(
        SubtitleOverlay.lines(primary: primary, secondary: secondary, time: 1) == [
            primary[0].text, secondary[0].text,
        ])
    #expect(
        SubtitleOverlay.lines(
            primary: primary, secondary: secondary, time: 1, removeLineBreaks: true) == [
                "另一个赢家也在庆祝胜利： 赌博业。", "there was another clear winner: the gambling industry.",
            ])
    #expect(primary[0].text.contains("\n") && secondary[0].text.contains("\r\n"))
    #expect(
        SubtitleOverlay.lines(
            primary: primary, secondary: secondary, time: 2, removeLineBreaks: true
        ).isEmpty)
}
