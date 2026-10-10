import Foundation
import Testing

@testable import BiliNextCore

private func streamRow(_ id: Int, codec: String = "avc1.640028", camel: Bool = true) -> [String:
    Any]
{
    [
        "id": id, "codecs": codec, "bandwidth": 1_000_000,
        camel ? "baseUrl" : "base_url": "https://example.com/video",
        "backup_url": ["https://example.com/video", "https://backup.example.com/video"],
        camel ? "SegmentBase" : "segment_base": camel
            ? ["Initialization": "0-699", "indexRange": "700-799"]
            : ["initialization": "0-699", "index_range": "700-799"],
    ]
}

@Test func dashQualityUsesActualCompatibleStreams() throws {
    let data: [String: Any] = [
        "accept_quality": [120, 80, 64],
        "accept_description": ["4K", "1080P", "720P"],
        "dash": [
            "video": [
                streamRow(80), streamRow(120, codec: "av01.0.12M.08"),
                streamRow(64, camel: false),
            ], "audio": [streamRow(30280, codec: "mp4a.40.2")],
        ],
    ]
    let result = try PlaybackParser.parse(data, preferredQuality: 120)
    #expect(result.qualityID == 80)
    #expect(result.qualities.map(\.value) == [80, 64])
    #expect(result.videoStream?.urls.count == 2)
    #expect(result.audioStream?.codec == "mp4a.40.2")
    #expect(try PlaybackParser.parse(data, preferredQuality: 64).qualityID == 64)
}

@Test func dashHandlesSilentMediaAndRejectsMissingSegments() throws {
    #expect(
        try PlaybackParser.parse(
            ["dash": ["video": [streamRow(80)], "audio": []]],
            preferredQuality: 80
        ).audioStream == nil)
    #expect(throws: APIError.self) {
        try PlaybackParser.parse(
            ["dash": ["video": [streamRow(80, codec: "av01")]]], preferredQuality: 80)
    }
    #expect(PlaybackParser.range("100-99") == nil)
    #expect(PlaybackParser.range("-1-99") == nil)
    #expect(PlaybackParser.range("0-99") == 0...99)
}

@Test func mp4DoesNotAdvertiseUndeliveredQualities() throws {
    let result = try PlaybackParser.parse(
        [
            "quality": 64, "accept_quality": [80, 64],
            "durl": [["url": "https://example.com/video.mp4"]],
        ], preferredQuality: 80)
    #expect(result.videoStream == nil)
    #expect(result.qualities.map(\.value) == [64])
    #expect(throws: APIError.self) {
        try PlaybackParser.parse(["durl": []], preferredQuality: 80)
    }
}

@Test func codecSelectionHonorsHardwareGateAndFallbacks() throws {
    let data: [String: Any] = [
        "dash": [
            "video": [
                streamRow(120),
                streamRow(120, codec: "hev1.1.6.L153.90"), streamRow(120, codec: "av01.0.12M.08"),
            ]
        ]
    ]
    #expect(
        try PlaybackParser.parse(data, preferredQuality: 120, allowAV1: true)
            .videoStream?.codec.hasPrefix("av01.") == true)
    #expect(
        try PlaybackParser.parse(data, preferredQuality: 120, allowAV1: false)
            .videoStream?.codec.hasPrefix("hev1") == true)
    #expect(
        try PlaybackParser.parse(data, preferredQuality: 120, allowAV1: false, allowHEVC: false)
            .videoStream?.codec.hasPrefix("avc1") == true)
    #expect(throws: APIError.self) {
        try PlaybackParser.parse(
            ["dash": ["video": [streamRow(120, codec: "av01.0.12M.08")]]],
            preferredQuality: 120, allowAV1: false)
    }
}
