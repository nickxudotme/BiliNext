import Foundation
import Testing

@testable import BiliNextCore

@Test func onlineViewerCountUsesAllClientsAndPreservesServerPrecision() {
    #expect(OnlineViewerCount(data: ["total": "123", "count": "7"])?.total == "123")
    #expect(OnlineViewerCount(data: ["total": " 10万+ "])?.total == "10万+")
    #expect(OnlineViewerCount(data: ["total": 42])?.total == "42")
    #expect(OnlineViewerCount(data: ["total": "0"])?.total == "0")
    #expect(OnlineViewerCount(data: ["total": "1.2万"])?.total == "1.2万")
}

@Test func onlineViewerCountHonorsHiddenOrUnavailableTotals() {
    #expect(OnlineViewerCount(data: ["total": "123", "show_switch": ["total": false]]) == nil)
    #expect(
        OnlineViewerCount(data: ["total": "123", "show_switch": ["total": true]])?.total == "123")
    for data: [String: Any] in [
        [:], ["count": "123"], ["total": ""], ["total": "--"], ["total": true],
        ["total": -1], ["total": "unknown"], ["total": NSNull()],
    ] {
        #expect(OnlineViewerCount(data: data) == nil)
    }
}

@Suite(.serialized)
struct OnlineViewerRequestTests {
    @Test func requestsOnlyTheCurrentVideoAndPart() async throws {
        let fixture = OnlineViewerRequestFixture(code: 0, data: ["total": "123", "count": "7"])
        defer { fixture.close() }
        let result = try await fixture.api.onlineViewerCount(bvid: "BV1111111111", cid: 42)
        #expect(result?.total == "123")
        let request = try #require(fixture.requests.first)
        #expect(request.url?.path == "/x/player/online/total")
        #expect(request.httpMethod == "GET")
        let items =
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(
            Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) }) == [
                "bvid": "BV1111111111", "cid": "42",
            ])
        #expect(fixture.requests.count == 1)
    }

    @Test func failureStaysAnErrorAndUnsupportedIDsNeverSend() async throws {
        let fixture = OnlineViewerRequestFixture(code: -403)
        defer { fixture.close() }
        do {
            _ = try await fixture.api.onlineViewerCount(bvid: "BV1111111111", cid: 42)
            Issue.record("Expected the API failure")
        } catch let error as APIError { #expect(error.code == -403) }
        #expect(fixture.requests.count == 1)
        for (bvid, cid) in [
            ("live:42", Int64(42)), ("space:7", 42), ("ep123", 42), ("BV1111111111", 0),
        ] {
            do {
                _ = try await fixture.api.onlineViewerCount(bvid: bvid, cid: cid)
                Issue.record("Expected invalid video parameters to fail locally")
            } catch let error as APIError { #expect(error.code == -1) }
        }
        #expect(fixture.requests.count == 1)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_LIVE_TEST"] == "1"))
func publicOnlineViewerSmoke() async throws {
    let api = BilibiliAPI(restoreSession: false)
    let detail = try await api.detail("BV1xx411c7mD")
    let cid = try #require(detail.pages.first?.cid)
    let count = try await api.onlineViewerCount(bvid: detail.video.bvid, cid: cid)
    // The service may explicitly hide the total; a successful read has no invented fallback.
    if let count { #expect(!count.total.isEmpty) }
}

private final class OnlineViewerRequestFixture: @unchecked Sendable {
    let api: BilibiliAPI
    private let lock = NSLock()
    private var received: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { received } }

    init(code: Int, data: [String: Any] = [:]) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OnlineViewerRequestProtocol.self]
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        OnlineViewerRequestProtocol.install { [self] request, client in
            lock.withLock { received.append(request) }
            client.respond(["code": code, "data": data, "message": "fixture"])
        }
    }

    func close() { OnlineViewerRequestProtocol.install(nil) }
}

private final class OnlineViewerRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest, OnlineViewerRequestProtocol) -> Void)?

    static func install(_ value: ((URLRequest, OnlineViewerRequestProtocol) -> Void)?) {
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
