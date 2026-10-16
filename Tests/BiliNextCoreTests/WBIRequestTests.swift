import Foundation
import Testing

@testable import BiliNextCore

@Suite(.serialized)
struct WBIRequestTests {
    @Test func refreshesRejectedKeyAndSignsAgain() async throws {
        let fixture = WBIRequestFixture { request, attempt in
            if request.url?.path == WBIRequestFixture.navPath {
                return .nav(fresh: attempt > 1)
            }
            return attempt == 1 ? .api(-403) : .api(0, data: ["value": "retried"])
        }
        defer { fixture.close() }

        let result = try await fixture.api.request(
            "/test/wbi", params: ["q": "中 文", "w_rid": "discard-me"], signed: true)
        #expect(result["value"] as? String == "retried")
        let requests = fixture.requests(to: "/test/wbi")
        #expect(requests.count == 2)
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 2)
        try expectSignature(requests[0], fresh: false)
        try expectSignature(requests[1], fresh: true)
        #expect(query(requests[0])["w_rid"] != query(requests[1])["w_rid"])
        #expect(query(requests[1])["q"] == "中 文")
    }

    @Test func stopsAfterOneRetryAndPreservesSecondError() async throws {
        let fixture = WBIRequestFixture { request, attempt in
            request.url?.path == WBIRequestFixture.navPath
                ? .nav(fresh: attempt > 1) : .api(-403, message: "failure \(attempt)")
        }
        defer { fixture.close() }

        do {
            _ = try await fixture.api.request("/test/wbi", signed: true)
            Issue.record("Expected the second WBI rejection")
        } catch let error as APIError {
            #expect(error.code == -403)
            #expect(error.message == "failure 2")
        }
        #expect(fixture.requests(to: "/test/wbi").count == 2)
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 2)
    }

    @Test func suppliesDefaultWebLocationAndPreservesExplicitValues() async throws {
        let fixture = WBIRequestFixture { request, _ in
            request.url?.path == WBIRequestFixture.navPath ? .nav() : .api(0)
        }
        defer { fixture.close() }

        for location in [nil, "1550102", ""] as [String?] {
            let params = location.map { ["web_location": $0] } ?? [:]
            _ = try await fixture.api.request("/test/wbi", params: params, signed: true)
            let request = try #require(fixture.requests(to: "/test/wbi").last)
            #expect(query(request)["web_location"] == (location ?? "1550101"))
            try expectSignature(request, fresh: false)
        }
        _ = try await fixture.api.request("/test/unsigned")
        #expect(query(try #require(fixture.requests(to: "/test/unsigned").last)).isEmpty)
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 1)
    }

    @Test func liveRequestsGetNoMainSiteWebLocation() async throws {
        let fixture = WBIRequestFixture { request, _ in
            request.url?.path == WBIRequestFixture.navPath ? .nav() : .api(0)
        }
        defer { fixture.close() }

        _ = try await fixture.api.request("/test/live", signed: true, live: true)
        let request = try #require(fixture.requests(to: "/test/live").last)
        #expect(request.url?.host == "api.live.bilibili.com")
        #expect(query(request)["web_location"] == nil)
        try expectSignature(request, fresh: false)
    }

    @Test func cancelledWriteStillReturnsTheServersAnswer() async throws {
        let fixture = WBIRequestFixture { request, _ in
            request.url?.path == "/test/write" ? nil : .api(0)
        }
        defer { fixture.close() }

        let task = Task {
            try await fixture.api.request("/test/write", form: ["action": "1"])
        }
        try await fixture.waitForRequest(to: "/test/write")
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        // The POST was sent; cancelling its caller neither tears it down nor drops the answer.
        fixture.respond(to: "/test/write", with: .api(0, data: ["value": "applied"]))
        let result = try await task.value
        #expect(result["value"] as? String == "applied")
        #expect(fixture.requests(to: "/test/write").count == 1)
    }

    @Test func leavesUnrelatedErrorsAndUnsignedRequestsAlone() async throws {
        let cases = [
            (signed: false, status: 200, code: -403),
            (signed: true, status: 200, code: -352),
            (signed: true, status: 200, code: -404),
            (signed: true, status: 403, code: -403),
            (signed: true, status: 412, code: -403),
        ]
        for testCase in cases {
            let fixture = WBIRequestFixture { request, _ in
                if request.url?.path == WBIRequestFixture.navPath { return .nav() }
                return .api(testCase.code, status: testCase.status)
            }
            defer { fixture.close() }
            do {
                _ = try await fixture.api.request("/test/wbi", signed: testCase.signed)
                Issue.record("Expected the original request failure")
            } catch let error as APIError {
                #expect(error.code == (testCase.status == 200 ? testCase.code : testCase.status))
            }
            #expect(fixture.requests(to: "/test/wbi").count == 1)
            #expect(
                fixture.requests(to: WBIRequestFixture.navPath).count == (testCase.signed ? 1 : 0))
        }
    }

    @Test func neverReplaysSignedPosts() async throws {
        let fixture = WBIRequestFixture { request, _ in
            request.url?.path == WBIRequestFixture.navPath ? .nav() : .api(-403)
        }
        defer { fixture.close() }
        do {
            _ = try await fixture.api.request(
                "/test/write", signed: true, form: ["value": "fixture"])
            Issue.record("Expected the POST rejection")
        } catch let error as APIError {
            #expect(error.code == -403)
        }
        let requests = fixture.requests(to: "/test/write")
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "POST")
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 1)
    }

    @Test func keyLookupFailureDoesNotReplayNavigation() async throws {
        let fixture = WBIRequestFixture { _, _ in .api(-403) }
        defer { fixture.close() }
        do {
            _ = try await fixture.api.request("/test/wbi", signed: true)
            Issue.record("Expected the key lookup rejection")
        } catch let error as APIError {
            #expect(error.code == -403)
        }
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 1)
        #expect(fixture.requests(to: "/test/wbi").isEmpty)
    }

    @Test func staleConcurrentRejectionKeepsTheAlreadyRefreshedKey() async throws {
        let fixture = WBIRequestFixture { request, attempt in
            if request.url?.path == WBIRequestFixture.navPath {
                return .nav(fresh: attempt > 1)
            }
            if request.url?.path == "/test/warm" { return .api(0) }
            return attempt == 1 ? nil : .api(0)
        }
        defer { fixture.close() }
        _ = try await fixture.api.request("/test/warm", signed: true)
        let first = Task { try await fixture.api.request("/test/first", signed: true) }
        let second = Task { try await fixture.api.request("/test/second", signed: true) }
        try await fixture.waitForRequest(to: "/test/first")
        try await fixture.waitForRequest(to: "/test/second")

        fixture.respond(to: "/test/first", with: .api(-403))
        _ = try await first.value
        fixture.respond(to: "/test/second", with: .api(-403))
        _ = try await second.value

        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 2)
        for path in ["/test/first", "/test/second"] {
            let requests = fixture.requests(to: path)
            #expect(requests.count == 2)
            try expectSignature(requests[0], fresh: false)
            try expectSignature(requests[1], fresh: true)
        }
    }

    @Test func cancellationDuringKeyRefreshStopsBeforeReplay() async throws {
        let fixture = WBIRequestFixture { request, attempt in
            if request.url?.path == WBIRequestFixture.navPath {
                return attempt == 1 ? .nav() : nil
            }
            return .api(-403)
        }
        defer { fixture.close() }
        let task = Task { try await fixture.api.request("/test/wbi", signed: true) }
        try await fixture.waitForRequest(to: WBIRequestFixture.navPath, count: 2)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(fixture.requests(to: "/test/wbi").count == 1)
        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 2)
    }

    @Test func delayedKeyLookupCannotOverwriteNewerKey() async throws {
        let fixture = WBIRequestFixture { request, attempt in
            if request.url?.path == WBIRequestFixture.navPath {
                return attempt == 1 ? nil : .nav(fresh: true)
            }
            return .api(0)
        }
        defer { fixture.close() }
        let delayed = Task { try await fixture.api.request("/test/delayed", signed: true) }
        try await fixture.waitForRequest(to: WBIRequestFixture.navPath)
        _ = try await fixture.api.request("/test/newer", signed: true)
        fixture.respond(to: WBIRequestFixture.navPath, with: .nav())
        _ = try await delayed.value
        _ = try await fixture.api.request("/test/cached", signed: true)

        #expect(fixture.requests(to: WBIRequestFixture.navPath).count == 2)
        for path in ["/test/delayed", "/test/newer", "/test/cached"] {
            try expectSignature(try #require(fixture.requests(to: path).first), fresh: true)
        }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items =
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func expectSignature(_ request: URLRequest, fresh: Bool) throws {
        let params = query(request)
        let timestamp = try #require(params["wts"].flatMap(Int.init))
        let key = try WBISigner.mixinKey(
            image: fresh ? WBIRequestFixture.freshImage : WBIRequestFixture.image,
            sub: fresh ? WBIRequestFixture.freshSub : WBIRequestFixture.sub)
        #expect(params["w_rid"] == WBISigner.sign(params, key: key, timestamp: timestamp)["w_rid"])
    }
}

private final class WBIRequestFixture: @unchecked Sendable {
    static let navPath = "/x/web-interface/nav"
    static let image = "7cd084941338484aae1ad9425b84077c"
    static let sub = "4932caff0ff746eab6f01bf08b70ac45"
    static let freshImage = String(repeating: "a", count: 32)
    static let freshSub = String(repeating: "b", count: 32)

    struct Response {
        let body: [String: Any]
        let status: Int

        static func api(
            _ code: Int, data: [String: Any] = [:], message: String = "fixture", status: Int = 200
        ) -> Response {
            Response(body: ["code": code, "data": data, "message": message], status: status)
        }

        static func nav(fresh: Bool = false) -> Response {
            .api(
                -101,
                data: [
                    "wbi_img": [
                        "img_url": "https://i0.hdslb.com/bfs/wbi/\(fresh ? freshImage : image).png",
                        "sub_url": "https://i0.hdslb.com/bfs/wbi/\(fresh ? freshSub : sub).png",
                    ]
                ])
        }
    }

    let api: BilibiliAPI
    private let lock = NSLock()
    private let route: (URLRequest, Int) -> Response?
    private var received: [(request: URLRequest, client: WBIRequestProtocol)] = []

    init(route: @escaping (URLRequest, Int) -> Response?) {
        self.route = route
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WBIRequestProtocol.self]
        config.httpCookieStorage?.setCookie(
            HTTPCookie(properties: [
                .name: "bili_jct", .value: "test-csrf", .domain: ".bilibili.com", .path: "/",
                .secure: "TRUE",
            ])!)
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        WBIRequestProtocol.install { [self] request, client in
            let attempt = lock.withLock {
                received.append((request, client))
                return received.filter { $0.request.url?.path == request.url?.path }.count
            }
            if let response = route(request, attempt) { client.respond(response) }
        }
    }

    func close() { WBIRequestProtocol.install(nil) }

    func requests(to path: String) -> [URLRequest] {
        lock.withLock { received.filter { $0.request.url?.path == path }.map(\.request) }
    }

    func waitForRequest(to path: String, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests(to: path).count < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(requests(to: path).count >= count)
    }

    func respond(to path: String, with response: Response) {
        let client = lock.withLock { received.first { $0.request.url?.path == path }?.client }
        client?.respond(response)
    }
}

private final class WBIRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let handlerLock = NSLock()
    private static var handler: ((URLRequest, WBIRequestProtocol) -> Void)?
    private let lock = NSLock()
    private var stopped = false

    static func install(_ value: ((URLRequest, WBIRequestProtocol) -> Void)?) {
        handlerLock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handlerLock.withLock { Self.handler }
        handler?(request, self)
    }

    override func stopLoading() { lock.withLock { stopped = true } }

    func respond(_ response: WBIRequestFixture.Response) {
        guard lock.withLock({ !stopped }) else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: response.body)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: response.status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
