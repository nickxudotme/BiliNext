import Foundation
import Testing

@testable import BiliNextCore

@Test func officialMirrorsComeBeforePeerMirrors() throws {
    let urls = [
        "https://xy58x144x144x10xy.mcdn.bilivideo.cn:8082/v1/resource/a.m4s",
        "https://mv0b973m.edge.mountaintoys.cn/upgcxcode/a.m4s",
        "https://upos-sz-mirrorhwo1.bilivideo.com/upgcxcode/a.m4s?os=hwbv",
        "https://cdn.example.com/a.m4s",
        "https://cn-gddg-ct-01-01.bilivideo.com/upgcxcode/a.m4s?os=bcache",
        "https://upos-sz-estgoss.bilivideo.com/upgcxcode/a.m4s?os=mcdn",
    ].compactMap(URL.init(string:))
    #expect(
        CDNPreference.ordered(urls).map { $0.host ?? "" } == [
            "upos-sz-mirrorhwo1.bilivideo.com", "cn-gddg-ct-01-01.bilivideo.com",
            "cdn.example.com", "xy58x144x144x10xy.mcdn.bilivideo.cn",
            "mv0b973m.edge.mountaintoys.cn", "upos-sz-estgoss.bilivideo.com",
        ])
}

@Test func parsedStreamsOpenOnTheOfficialCDN() throws {
    let row: [String: Any] = [
        "baseUrl": "http://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/a.m4s",
        "backupUrl": ["https://upos-sz-mirrorcos.bilivideo.com/a.m4s"],
        "codecs": "avc1", "bandwidth": 1,
        "SegmentBase": ["Initialization": "0-100", "indexRange": "101-200"],
    ]
    let stream = try #require(PlaybackParser.stream(row))
    #expect(stream.urls.first?.host == "upos-sz-mirrorcos.bilivideo.com")
    #expect(stream.urls.count == 2)
}
