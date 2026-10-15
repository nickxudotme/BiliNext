import Foundation
import Testing

@testable import BiliNextCore

@Test(arguments: [0, 1, 2, 9])
func commentsReadTheViewersActionWithoutConfusingUploaderLikes(_ action: Int) throws {
    let parsed = try #require(
        BiliNextCore.Comment.parse([
            "rpid": Int64(7), "action": action, "like": 5,
            "up_action": ["like": true], "content": ["message": "测试"],
        ]))
    #expect(parsed.liked == (action == 1) && parsed.likedByUploader && parsed.likes == 5)
    let missing = try #require(BiliNextCore.Comment.parse(["rpid": Int64(8)]))
    #expect(!missing.liked)
}

@Suite(.serialized)
struct CommentLikeRequestTests {
    @Test func likeAndUnlikePostTheDocumentedFormAndSnapshotTheAccountCookies() async throws {
        let fixture = CommentLikeFixture()
        defer { fixture.close() }
        for liked in [true, false] {
            try await fixture.api.likeComment(
                aid: 100, replyID: 9_876_543_210_123, liked: liked, expectedUserID: 42)
        }
        let requests = fixture.requests
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.url?.path == "/x/v2/reply/action" && request.httpMethod == "POST")
            #expect((request.url?.query ?? "").isEmpty)
            #expect(
                request.value(forHTTPHeaderField: "Content-Type")
                    == "application/x-www-form-urlencoded")
            var components = URLComponents()
            components.percentEncodedQuery = String(
                data: request.httpBody ?? Data(), encoding: .utf8)
            let form = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
            #expect(
                form == [
                    "type": "1", "oid": "100", "rpid": "9876543210123",
                    "action": index == 0 ? "1" : "0", "csrf": "test-csrf",
                ])
            #expect(!request.httpShouldHandleCookies)
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            #expect(cookie.contains("DedeUserID=42") && cookie.contains("SESSDATA=test-session"))
        }
    }

    @Test func missingCredentialsAndChangedAccountsNeverSend() async throws {
        for missing in ["SESSDATA", "bili_jct", "DedeUserID"] {
            let fixture = CommentLikeFixture(missingCookie: missing)
            defer { fixture.close() }
            do {
                try await fixture.api.likeComment(
                    aid: 100, replyID: 7, liked: true, expectedUserID: 42)
                Issue.record("Expected missing credentials to fail locally")
            } catch let error as APIError { #expect(error.code == -101) }
            #expect(fixture.requests.isEmpty)
        }
        let fixture = CommentLikeFixture()
        defer { fixture.close() }
        do {
            try await fixture.api.likeComment(aid: 100, replyID: 7, liked: true, expectedUserID: 43)
            Issue.record("Expected the different account to fail locally")
        } catch let error as APIError { #expect(error.code == -101) }
        #expect(fixture.requests.isEmpty)
    }

    @Test func invalidTargetsNeverSendAndWriteErrorsAreNotRetried() async throws {
        let fixture = CommentLikeFixture(code: -403)
        defer { fixture.close() }
        for (aid, reply, user) in [(Int64(0), Int64(7), Int64(42)), (100, 0, 42), (100, 7, 0)] {
            do {
                try await fixture.api.likeComment(
                    aid: aid, replyID: reply, liked: true, expectedUserID: user)
                Issue.record("Expected invalid parameters to fail locally")
            } catch let error as APIError { #expect(error.code == -1) }
        }
        #expect(fixture.requests.isEmpty)
        do {
            try await fixture.api.likeComment(aid: 100, replyID: 7, liked: true, expectedUserID: 42)
            Issue.record("Expected the write rejection")
        } catch let error as APIError {
            #expect(error.code == -403 && error.message == "mock rejection")
        }
        #expect(fixture.requests.count == 1)
    }
}

private final class CommentLikeFixture: @unchecked Sendable {
    let api: BilibiliAPI
    private let lock = NSLock()
    private var received: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { received } }

    init(missingCookie: String? = nil, code: Int = 0) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommentLikeProtocol.self]
        for (name, value) in [
            "SESSDATA": "test-session", "bili_jct": "test-csrf", "DedeUserID": "42",
        ] where name != missingCookie {
            config.httpCookieStorage?.setCookie(
                HTTPCookie(properties: [
                    .name: name, .value: value, .domain: ".bilibili.com", .path: "/",
                    .secure: "TRUE",
                ])!)
        }
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        CommentLikeProtocol.install { [self] request, client in
            lock.withLock { received.append(request) }
            client.respond(code: code)
        }
    }

    func close() { CommentLikeProtocol.install(nil) }
}

private final class CommentLikeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest, CommentLikeProtocol) -> Void)?

    static func install(_ value: ((URLRequest, CommentLikeProtocol) -> Void)?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        // URLSession exposes POST bodies as streams to URLProtocol on macOS.
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.withLock { Self.handler }?(captured, self)
    }
    override func stopLoading() {}

    func respond(code: Int) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: ["code": code, "message": "mock rejection"])
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
