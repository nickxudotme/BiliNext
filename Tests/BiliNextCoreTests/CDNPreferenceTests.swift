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

@Test func officialMediaMovesToTheChosenMirrorKeepingFallbacks() throws {
    let urls = [
        "https://cn-zjjh-ct-04-06.bilivideo.com/upgcxcode/1/2/a-1-100026.m4s?e=1&upsig=x",
        "https://upos-sz-mirrorbd.bilivideo.com/upgcxcode/1/2/a-1-100026.m4s?e=1&upsig=x",
        "https://xy1x2x3x4xy.mcdn.bilivideo.cn:8082/v1/resource/a.m4s",
    ].compactMap(URL.init(string:))
    let moved = CDNPreference.preferring("upos-sz-mirrorali.bilivideo.com", in: urls)
    #expect(moved.count == 4)
    #expect(moved[0].host == "upos-sz-mirrorali.bilivideo.com")
    #expect(moved[0].path == urls[0].path && moved[0].query == urls[0].query)
    #expect(Array(moved.dropFirst()) == urls)
    // Nothing official to move, or no mirror chosen: unchanged.
    #expect(CDNPreference.preferring("upos-sz-mirrorali.bilivideo.com", in: [urls[2]]) == [urls[2]])
    #expect(CDNPreference.preferring(nil, in: urls) == urls)
    let redirector = try #require(
        URL(string: "https://upos-sz-302.bilivideo.com/upgcxcode/1/a.m4s"))
    #expect(
        CDNPreference.preferring("upos-sz-mirrorali.bilivideo.com", in: [redirector]) == [
            redirector
        ])
}
