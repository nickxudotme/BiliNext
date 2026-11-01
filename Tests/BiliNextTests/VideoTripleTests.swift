import Foundation
import SwiftUI
import Testing

@testable import BiliNext
@testable import BiliNextCore

#if DEBUG
    import SwiftFeedback
#endif

@MainActor
@Suite(.serialized)
struct VideoTripleTests {
    @Test func missingBrowserIdentifierIsPreparedBeforeOneTripleWrite() async throws {
        let fixture = VideoTripleFixture(browserIdentifier: false)
        defer { fixture.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(
            fixture.requests.map { $0.url!.path } == [
                "/x/frontend/finger/spi", "/x/web-interface/archive/like/triple",
            ])
        let request = try #require(fixture.requests.last)
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookie.contains("buvid3=fixture-browser") && cookie.contains("DedeUserID=42"))
        #expect(!request.httpShouldHandleCookies)
        #expect(request.httpMethod == "POST" && fixture.model.toast == "三连成功")
        #expect(fixture.model.relation == VideoRelation(liked: true, coins: 2, favorited: true))
    }

    @Test func existingIdentifierIsReusedAndTheWriteIsNotReplayedAfterARejection() async throws {
        let fixture = VideoTripleFixture(code: -403)
        defer { fixture.close() }
        fixture.model.triple()
        fixture.model.triple()  // A second click while pending must not spend coins again.
        try await fixture.waitForWrite()
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests[0].url?.path == "/x/web-interface/archive/like/triple")
        #expect(fixture.model.toast?.contains("-403") == true)
        #expect(fixture.model.relation == VideoRelation() && fixture.model.tripleCount == 0)
        #expect(fixture.model.tripleRejectedVideo?.bvid == "BV1111111111")
    }

    @Test func otherFailuresDoNotOfferTheAccountRejectionRecovery() async throws {
        let fixture = VideoTripleFixture(code: -111)
        defer { fixture.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(fixture.model.tripleRejectedVideo == nil)
        #expect(fixture.model.toast?.contains("-111") == true)
        #expect(fixture.requests.count == 1)
    }

    @Test func lateTripleResultsDoNotAffectAnotherVideoOrAccount() async throws {
        for code in [-403, 0] {
            for changeAccount in [false, true] {
                let fixture = VideoTripleFixture(code: code) { model in
                    if changeAccount {
                        model.accountGeneration = UUID()
                        model.profile = UserProfile(id: 43, name: "另一个离线账号")
                    } else {
                        model.relationVideo = "BV2222222222"
                    }
                }
                defer { fixture.close() }
                fixture.model.triple()
                try await fixture.waitForWrite()
                #expect(fixture.model.tripleRejectedVideo == nil)
                #expect(fixture.model.toast == nil)
                #expect(fixture.model.relation == VideoRelation())
                #expect(fixture.model.tripleCount == 0)
                #expect(fixture.requests.count == 1)
            }
        }
    }

    @Test func unsuccessfulCoinFlagDoesNotApplyMultiplyOrClaimFullSuccess() async throws {
        let fixture = VideoTripleFixture(coin: false)
        defer { fixture.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(fixture.model.relation.liked && fixture.model.relation.favorited)
        #expect(fixture.model.relation.coins == 0)
        #expect(fixture.model.detail?.stats.coins == 100)
        #expect(fixture.model.toast?.contains("投币未成功") == true)
        #expect(fixture.model.tripleCount == 0)
    }

    @Test func addedCoinIsAddedToTheExistingCountOnce() async throws {
        let fixture = VideoTripleFixture(multiply: 1)
        defer { fixture.close() }
        fixture.model.relation.coins = 1
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(fixture.model.relation.coins == 2)
        #expect(fixture.model.detail?.stats.coins == 101)
        #expect(fixture.model.tripleCount == 1 && fixture.model.toast == "三连成功")
    }

    @Test func failedIdentifierPreparationNeverStartsAnAccountWrite() async throws {
        let fixture = VideoTripleFixture(browserIdentifier: false, identifierCode: -412)
        defer { fixture.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(fixture.requests.map { $0.url!.path } == ["/x/frontend/finger/spi"])
        #expect(fixture.model.relation == VideoRelation() && fixture.model.tripleCount == 0)
        #expect(fixture.model.toast?.contains("412") == true)
    }

    @Test func accountChangeDuringIdentifierPreparationNeverStartsTheWrite() async throws {
        let fixture = VideoTripleFixture(browserIdentifier: false, switchAccount: true)
        defer { fixture.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        #expect(fixture.requests.map { $0.url!.path } == ["/x/frontend/finger/spi"])
        #expect(fixture.model.relation == VideoRelation() && fixture.model.tripleCount == 0)
        #expect(fixture.model.toast?.contains("重新扫码登录") == true)
    }

    @Test func anonymousClientLoginAndLogoutStayInTheirOwnCookieJar() async throws {
        let fixture = VideoTripleFixture()
        defer { fixture.close() }
        // restoreSession:false defaults to an ephemeral credential backend. Even a
        // simulated QR success and logout must not save or delete a Keychain item.
        let status = try await fixture.model.api.pollLogin("fixture-key")
        if case .success = status {} else { Issue.record("Expected the fixture login") }
        let before = await fixture.model.api.officialPlayerCookies()
        #expect(before.contains { $0.name == "SESSDATA" && $0.value == "fixture-session" })
        try await fixture.model.api.logout()
        let after = await fixture.model.api.officialPlayerCookies()
        #expect(after.isEmpty)
        #expect(fixture.requests.map { $0.url!.path } == ["/x/passport-login/web/qrcode/poll"])
    }

    #if DEBUG
        @Test func tripleFeedbackContainsOnlyCookiePresenceAndTheRejectionCode() async throws {
            let fixture = VideoTripleFixture(code: -403)
            defer { fixture.close() }
            fixture.model.triple()
            try await fixture.waitForWrite()
            let events = FeedbackRecorder.shared.snapshot().filter {
                $0.name == "interaction.triple"
            }
            let requested = try #require(events.last { $0.fields["phase"] == "requested" })
            #expect(requested.fields["hasBrowserIdentifierBeforePreparation"] == "true")
            #expect(requested.fields["hasSession"] == "true")
            #expect(requested.fields["hasCSRF"] == "true")
            #expect(events.last?.fields["apiCode"] == "-403")
            let fields = String(describing: requested.fields)
            #expect(!fields.contains("fixture-session"))
            #expect(!fields.contains("fixture-csrf"))
            #expect(!fields.contains("fixture-browser"))
        }
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BILINEXT_TRIPLE_UI_TEST"] == "1"))
    func rejectedTripleOffersRecoveryInANativeWindow() async throws {
        let fixture = VideoTripleFixture(code: -403)
        defer { fixture.close() }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlaybackView(model: fixture.model))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        fixture.model.triple()
        try await fixture.waitForWrite()
        for _ in 0..<100 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(window.attachedSheet)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let actions = buttons(in: try #require(sheet.contentView))
        #expect(actions.contains { $0.title == "在网页中打开视频" })
        let close = try #require(actions.first { $0.title == "关闭" })
        close.performClick(nil)
        for _ in 0..<100 where fixture.model.tripleRejectedVideo != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.model.tripleRejectedVideo == nil)
        #expect(
            fixture.requests.filter { $0.url?.path == "/x/web-interface/archive/like/triple" }
                .count == 1)
    }
}

@MainActor
private final class VideoTripleFixture {
    let model: AppModel
    private let directory: URL
    private let sessionConfiguration: URLSessionConfiguration
    private(set) var requests: [URLRequest] = []

    init(
        browserIdentifier: Bool = true, coin: Bool = true, multiply: Int = 2,
        code: Int = 0, identifierCode: Int = 0, switchAccount: Bool = false,
        beforeWriteResponse: ((AppModel) -> Void)? = nil
    ) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        sessionConfiguration = config
        config.protocolClasses = [VideoTripleProtocol.self]
        var cookies = [
            "SESSDATA": "fixture-session", "bili_jct": "fixture-csrf", "DedeUserID": "42",
        ]
        if browserIdentifier { cookies["buvid3"] = "fixture-browser" }
        for (name, value) in cookies {
            config.httpCookieStorage?.setCookie(
                HTTPCookie(properties: [
                    .name: name, .value: value, .domain: ".bilibili.com", .path: "/",
                    .secure: "TRUE",
                ])!)
        }
        let api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        model = AppModel(
            sessionStore: SessionStore(directory: directory), managesPlaybackTabs: false, api: api)
        model.profile = UserProfile(id: 42, name: "离线测试")
        let video = Video(bvid: "BV1111111111", title: "测试", aid: 100)
        model.detail = VideoDetail(
            video: video, pages: [], description: "", stats: VideoStats(coins: 100))
        model.relationVideo = video.bvid
        model.relationLoaded = true
        VideoTripleProtocol.handler = { [weak self] request, connection in
            Task { @MainActor in
                guard let self else { return }
                self.requests.append(request)
                if request.url?.path == "/x/frontend/finger/spi" {
                    if switchAccount {
                        self.sessionConfiguration.httpCookieStorage?.setCookie(
                            HTTPCookie(properties: [
                                .name: "DedeUserID", .value: "43", .domain: ".bilibili.com",
                                .path: "/", .secure: "TRUE",
                            ])!)
                    }
                    connection.respond(code: identifierCode, data: ["b_3": "fixture-browser"])
                } else if request.url?.path == "/x/passport-login/web/qrcode/poll" {
                    connection.respond(code: 0, data: ["code": 0])
                } else {
                    beforeWriteResponse?(self.model)
                    let hasBrowser =
                        browserIdentifier
                        || (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("buvid3=")
                    connection.respond(
                        code: hasBrowser ? code : -403,
                        data: [
                            "like": true, "coin": coin, "fav": true, "multiply": multiply,
                        ])
                }
            }
        }
    }

    func waitForWrite() async throws {
        for _ in 0..<100 where model.interactionBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.interactionBusy)
    }

    func close() {
        VideoTripleProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class VideoTripleProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, VideoTripleProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}

    func respond(code: Int, data: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "code": code, "message": "账号异常，操作失败", "data": data,
        ])
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
