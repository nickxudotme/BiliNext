import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func qualitySwitchUsesCurrentSourcePreferencesAndKeepsPausedPosition() async throws {
    // Override only this test process's argument domain; never persist user settings.
    let defaults = UserDefaults.standard
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let fixture = QualitySwitchRequestFixture()
    defer { fixture.close() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
        sessionStore: SessionStore(directory: directory), managesPlaybackTabs: false,
        api: fixture.api)
    let core = try MPVPlayer(videoOutput: "null")
    // API responses contain CDN URLs so mirror selection is exercised. FFmpeg must reject
    // their protocols locally: this test never downloads the returned media.
    core.set("stream-lavf-o", "protocol_whitelist=file")
    core.muted = true
    model.mpv = core
    model.mediaID = "BV1111111111"
    model.pageID = 42
    model.detail = VideoDetail(
        video: Video(bvid: "BV1111111111", title: "fixture", episodeID: 7),
        pages: [VideoPage(cid: 42, number: 1, title: "fixture")], description: "")
    defer {
        model.stopMedia()
        if let observer = model.observer {
            model.player.removeTimeObserver(observer)
            model.observer = nil
        }
    }

    // The first change exercises every preference that used to be omitted. The second
    // proves a retained tab reads settings again instead of retaining its first snapshot.
    for (quality, codec, lossless, mirror, host, audioBitrate) in [
        (80, "avc", true, "hw", "upos-sz-mirrorhw.bilivideo.com", 900_000),
        (112, "hevc", false, "cos", "upos-sz-mirrorcos.bilivideo.com", 128_000),
    ] {
        var overrides = original
        overrides[Preferences.preferredCodec] = codec
        overrides[Preferences.prefersLossless] = lossless
        overrides[Preferences.cdnMirror] = mirror
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        model.qualitySwitchState = (42.5, false)
        model.selectQuality(quality)
        await model.qualityTask?.value

        let source = try #require(core.diagnosticContext)
        #expect(source.requestedQuality == quality && source.actualQuality == quality)
        #expect(source.codec == (codec == "avc" ? "avc1.640028" : "hev1.1.6.L120"))
        #expect(source.audioBitrate == audioBitrate)
        #expect(source.videoHost == host && source.audioHost == host)
        #expect(model.recoveryPosition == 42.5)
        #expect(!model.playbackIntent && core.flag("pause"))
        #expect(model.qualitySwitchState == nil)
        #expect(model.playerError == nil)
        core.stop()
    }

    #expect(fixture.requests.map(\.quality) == [80, 112])
    #expect(fixture.requests.allSatisfy { $0.episodeID == "7" && $0.cid == "42" })
}

private final class QualitySwitchRequestFixture: @unchecked Sendable {
    struct Request {
        let quality: Int
        let episodeID: String?
        let cid: String?
    }

    let api: BilibiliAPI
    private let lock = NSLock()
    private var received: [Request] = []
    var requests: [Request] { lock.withLock { received } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QualitySwitchRequestProtocol.self]
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        QualitySwitchRequestProtocol.install { [self] request, client in
            guard request.url?.path == "/pgc/player/web/playurl" else {
                client.respond(["code": -400, "message": "Unexpected request"])
                return
            }
            let items =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let quality = Int(query["qn"] ?? "") ?? 0
            lock.withLock {
                received.append(
                    Request(quality: quality, episodeID: query["ep_id"], cid: query["cid"]))
            }
            func stream(_ codec: String, bandwidth: Int) -> [String: Any] {
                [
                    "id": quality, "codecs": codec, "bandwidth": bandwidth,
                    "baseUrl":
                        "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/fixture/\(codec).m4s",
                    "SegmentBase": ["Initialization": "0-3", "indexRange": "4-7"],
                ]
            }
            client.respond([
                "code": 0,
                "result": [
                    "accept_quality": [quality], "accept_description": ["fixture"],
                    "dash": [
                        "video": [
                            stream("av01.0.08M.08", bandwidth: 1_000_000),
                            stream("hev1.1.6.L120", bandwidth: 2_000_000),
                            stream("avc1.640028", bandwidth: 3_000_000),
                        ],
                        "audio": [stream("mp4a.40.2", bandwidth: 128_000)],
                        "flac": ["audio": stream("fLaC", bandwidth: 900_000)],
                    ],
                ],
            ])
        }
    }

    func close() { QualitySwitchRequestProtocol.install(nil) }
}

private final class QualitySwitchRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest, QualitySwitchRequestProtocol) -> Void)?

    static func install(_ value: ((URLRequest, QualitySwitchRequestProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.handler }?(request, self) }
    override func stopLoading() {}

    func respond(_ body: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
