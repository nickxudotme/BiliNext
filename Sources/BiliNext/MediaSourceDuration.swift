import CMPV
import Foundation

/// Read a source container's declared duration without joining the user's player.
enum MediaSourceDuration {
    static func load(_ url: URL) async -> Double? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .utility) { probe(url) }
        let duration = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        return Task.isCancelled ? nil : duration
    }

    private static func probe(_ url: URL) -> Double? {
        guard !Task.isCancelled, let core = mpv_create() else { return nil }
        // Creation, reads and teardown all remain off the main actor. Network
        // termination may wait for I/O even after the caller has cancelled.
        defer { mpv_terminate_destroy(core) }
        let options = [
            "config": "no", "terminal": "no", "vo": "null", "ao": "null",
            "mute": "yes", "pause": "yes", "idle": "yes", "keep-open": "yes",
            "hwdec": "no", "osc": "no", "input-default-bindings": "no",
            "load-scripts": "no", "sub-auto": "no", "audio-file-auto": "no",
            "cache": "no", "demuxer-readahead-secs": "0", "network-timeout": "2",
            "demuxer-lavf-probe-info": "no",
            "user-agent": "Mozilla/5.0", "referrer": "https://www.bilibili.com/",
        ]
        for (name, value) in options {
            guard mpv_set_option_string(core, name, value) >= 0 else { return nil }
        }
        guard !Task.isCancelled, mpv_initialize(core) >= 0 else { return nil }
        let arguments = ["loadfile", url.absoluteString]
        let strings = arguments.map { strdup($0) }
        defer { for value in strings { free(value) } }
        var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
        guard mpv_command_async(core, 1, &pointers) >= 0 else { return nil }
        // The two-second network timeout also bounds a blocked read during
        // teardown; normal header reads complete well within this poll budget.
        let deadline = ContinuousClock.now + .seconds(3)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            guard let event = mpv_wait_event(core, 0.05) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                var duration = 0.0
                guard mpv_get_property(core, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0,
                    duration.isFinite, duration > 0, !Task.isCancelled
                else { return nil }
                return duration
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return nil
            case MPV_EVENT_COMMAND_REPLY:
                if event.pointee.reply_userdata == 1, event.pointee.error < 0 { return nil }
            default: break
            }
        }
        return nil
    }
}
