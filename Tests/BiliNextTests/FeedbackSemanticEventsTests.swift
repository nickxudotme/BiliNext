#if DEBUG
    import Foundation
    import SwiftFeedback
    import Testing

    @testable import BiliNext
    @testable import BiliNextCore

    @MainActor
    @Test func feedbackRecordsSeekIntentWithoutRecordingInvalidValues() {
        let model = AppModel()
        let count = FeedbackRecorder.shared.snapshot().filter {
            $0.name == "playback.seekRequested"
        }.count
        model.seek(.nan)
        #expect(
            FeedbackRecorder.shared.snapshot().filter {
                $0.name == "playback.seekRequested"
            }.count == count)
        model.time = 12
        model.seek(25)
        let event = FeedbackRecorder.shared.snapshot().last { $0.name == "playback.seekRequested" }
        #expect(event?.fields["from"] == "12.0")
        #expect(event?.fields["to"] == "25.0")
        #expect(event?.fields["engine"] == "avplayer")
    }

    @MainActor
    @Test func feedbackRecordsBackgroundVideoOpenWithoutLoadingMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(sessionStore: SessionStore(directory: directory))
        model.open(Video(bvid: "BVFeedbackTest", title: "离线反馈测试"), background: true)
        let event = FeedbackRecorder.shared.snapshot().last { $0.name == "navigation.openVideo" }
        #expect(event?.fields["videoID"] == "BVFeedbackTest")
        #expect(event?.fields["background"] == "true")
        #expect(model.selected == nil)
        #expect(model.mpv == nil)
    }
#endif
