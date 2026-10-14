import Foundation

enum PlaybackParser {
    static func parse(
        _ data: [String: Any], preferredQuality: Int,
        allowAV1: Bool = false, allowHEVC: Bool = true
    ) throws -> Playback {
        let ids = data["accept_quality"] as? [Int] ?? []
        let labels = data["accept_description"] as? [String] ?? []
        func label(_ value: Int) -> String {
            if let index = ids.firstIndex(of: value), index < labels.count { return labels[index] }
            return [
                16: "360P", 32: "480P", 64: "720P", 80: "1080P", 112: "1080P 高码率",
                116: "1080P 60帧", 120: "4K", 125: "HDR", 126: "杜比视界", 127: "8K",
            ][value]
                ?? "清晰度 \(value)"
        }
        if let dash = data["dash"] as? [String: Any] {
            // AV1 is enabled by the caller only when hardware decoding is available.
            let videos = (dash["video"] as? [[String: Any]] ?? []).compactMap {
                row -> (Int, PlaybackStream)? in
                let quality = (row["id"] as? NSNumber)?.intValue ?? 0
                guard quality > 0, ![125, 126].contains(quality), let stream = stream(row),
                    stream.codec.hasPrefix("avc1")
                        || (allowHEVC
                            && (stream.codec.hasPrefix("hev1") || stream.codec.hasPrefix("hvc1")))
                        || (allowAV1 && stream.codec.hasPrefix("av01."))
                else { return nil }
                return (quality, stream)
            }
            let available = Set(videos.map { $0.0 }).sorted(by: >)
            guard let highest = available.first else {
                throw APIError(code: -1, message: "没有适合当前原生解码能力的 SDR 视频流")
            }
            let actual = available.contains(preferredQuality) ? preferredQuality : highest
            let candidates = videos.filter { $0.0 == actual }
            func rank(_ stream: PlaybackStream) -> Int {
                if stream.codec.hasPrefix("av01.") { return 0 }
                if stream.codec.hasPrefix("hev1") || stream.codec.hasPrefix("hvc1") { return 1 }
                return 2
            }
            let chosen = candidates.min { rank($0.1) < rank($1.1) }!
            let audio = (dash["audio"] as? [[String: Any]] ?? []).compactMap(stream)
                .filter { $0.codec.hasPrefix("mp4a") }
                .max { $0.bandwidth < $1.bandwidth }
            // An explicitly empty audio list is valid for silent media. Reject unsupported audio.
            if let rows = dash["audio"] as? [[String: Any]], !rows.isEmpty, audio == nil {
                throw APIError(code: -1, message: "当前音频编码不适合原生播放器")
            }
            return Playback(
                url: chosen.1.urls[0], quality: label(actual), qualityID: actual,
                qualities: available.map { PlaybackQuality(value: $0, label: label($0)) },
                videoStream: chosen.1, audioStream: audio)
        }
        let segments = data["durl"] as? [[String: Any]] ?? []
        let candidates =
            segments.count == 1
            ? ([segments[0]["url"] as? String ?? ""]
                + (segments[0]["backup_url"] as? [String] ?? []))
                .compactMap(secureURL)
            : []
        guard let url = CDNPreference.ordered(candidates).first else {
            throw APIError(code: -1, message: "当前视频未提供可播放的 DASH 或单段 MP4")
        }
        let actual = (data["quality"] as? NSNumber)?.intValue ?? 0
        return Playback(
            url: url, quality: label(actual), qualityID: actual,
            qualities: [PlaybackQuality(value: actual, label: label(actual))],
            videoStream: nil, audioStream: nil)
    }

    static func stream(_ row: [String: Any]) -> PlaybackStream? {
        let base = row["baseUrl"] as? String ?? row["base_url"] as? String ?? ""
        let backups = (row["backupUrl"] as? [String] ?? []) + (row["backup_url"] as? [String] ?? [])
        var urls: [URL] = []
        for text in [base] + backups {
            if let url = secureURL(text), !urls.contains(url) { urls.append(url) }
        }
        let segment =
            row["SegmentBase"] as? [String: Any] ?? row["segment_base"] as? [String: Any] ?? [:]
        guard !urls.isEmpty,
            let initialization = range(
                segment["Initialization"] as? String ?? segment["initialization"] as? String),
            let index = range(segment["indexRange"] as? String ?? segment["index_range"] as? String)
        else { return nil }
        return PlaybackStream(
            urls: CDNPreference.ordered(urls), codec: row["codecs"] as? String ?? "",
            bandwidth: (row["bandwidth"] as? NSNumber)?.intValue ?? 0,
            initialization: initialization, index: index)
    }

    static func range(_ text: String?) -> ClosedRange<Int64>? {
        let parts = text?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]),
            start >= 0, end >= start, end - start < 32 * 1024 * 1024
        else { return nil }
        return start...end
    }
}
