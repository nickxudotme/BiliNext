import Foundation
import Testing

@testable import BiliNextCore

private struct ExperienceResponse {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var data = Data()
    var failure: URLError?
    static func json(_ value: [String: Any]) throws -> Self {
        Self(data: try JSONSerialization.data(withJSONObject: value))
    }
}
private final class ExperienceProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> ExperienceResponse)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var failureWork: DispatchWorkItem?
    override func startLoading() {
        do {
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                request.httpBody = body
            }
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else { throw URLError(.badServerResponse) }
            let response = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                    headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
            if !response.data.isEmpty { client?.urlProtocol(self, didLoad: response.data) }
            if let failure = response.failure {
                // Simulate a connection dropping after the already received bytes were delivered.
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: failure)
                }
                failureWork = work
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03, execute: work)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { failureWork?.cancel() }
}

@Suite(.serialized)
struct ExperienceCoreTests {
    private func config(_ handler: @escaping (URLRequest) throws -> ExperienceResponse)
        -> URLSessionConfiguration
    {
        ExperienceProtocol.lock.lock()
        ExperienceProtocol.handler = handler
        ExperienceProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExperienceProtocol.self]
        return config
    }
    private func login(id: Int64 = 42, tokenID: Int64 = 42) -> [String: Any] {
        [
            "cookie_info": [
                "cookies": [
                    ["name": "DedeUserID", "value": String(id)],
                    ["name": "SESSDATA", "value": "test-session"],
                    ["name": "bili_jct", "value": "test-csrf"],
                ]
            ], "token_info": ["mid": tokenID, "access_token": "test-access", "expires_in": 3600],
        ]
    }
    @Test func clientLoginRejectsMismatchedAccountsWithoutReplacingExistingSession() async throws {
        let api = BilibiliAPI(restoreSession: false)
        try await api.installClientLogin(login())
        do {
            try await api.installClientLogin(login(id: 43))
            Issue.record("accepted mismatched credentials")
        } catch {}
        let cookies = await api.officialPlayerCookies()
        let userID = cookies.first { $0.name == "DedeUserID" }?.value
        #expect(userID == "42")
        #expect(try await api.authorizedClient(expectedUserID: 42)?.accountID == 42)
        try await api.logout()
        #expect(try await api.authorizedClient() == nil)
        #expect(await api.officialPlayerCookies().isEmpty)
    }
    @Test func clientTripleWritesOnceAndReadsConfirmedTotalWithoutCookies() async throws {
        var writes = 0
        let api = BilibiliAPI(
            restoreSession: false,
            sessionConfiguration: config { request in
                if request.url?.path == "/x/v2/view/like/triple" {
                    writes += 1
                    #expect(request.url?.host == "app.bilibili.com")
                    #expect(!request.httpShouldHandleCookies)
                    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                    let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    #expect(form.contains("access_key=test-access") && form.contains("sign="))
                    #expect(!form.contains("SESSDATA") && !form.contains("csrf"))
                    return try .json(["code": 0])
                }
                #expect(request.url?.path == "/x/web-interface/archive/relation")
                return try .json(["code": 0, "data": ["like": true, "coin": 2, "favorite": true]])
            })
        try await api.installClientLogin(login())
        let result = try await api.tripleVideo(aid: 123, expectedUserID: 42)
        #expect(result.liked && result.favorited && result.coins == 2 && result.coinsAreTotal)
        #expect(writes == 1)
    }
    @Test func rejectedClientWriteNeverFallsBackToWebAndWrongAccountNeverSends() async throws {
        var paths: [String] = []
        let api = BilibiliAPI(
            restoreSession: false,
            sessionConfiguration: config { request in
                paths.append(request.url!.path)
                return try .json(["code": -403, "message": "rejected"])
            })
        try await api.installClientLogin(login())
        do {
            _ = try await api.tripleVideo(aid: 123, expectedUserID: 43)
            Issue.record("wrong account wrote")
        } catch {}
        #expect(paths.isEmpty)
        do {
            _ = try await api.tripleVideo(aid: 123, expectedUserID: 42)
            Issue.record("rejection ignored")
        } catch let error as APIError { #expect(error.code == -403) }
        #expect(paths == ["/x/v2/view/like/triple"])
    }
    @Test func unknownClientWriteDoesNotReplayOrFallBack() async throws {
        var paths: [String] = []
        let api = BilibiliAPI(
            restoreSession: false,
            sessionConfiguration: config { request in
                paths.append(request.url!.path)
                throw URLError(.networkConnectionLost)
            })
        try await api.installClientLogin(login())
        do {
            _ = try await api.tripleVideo(aid: 123, expectedUserID: 42)
            Issue.record("ambiguous write accepted")
        } catch let error as APIError { #expect(error.code == -90001) }
        #expect(paths == ["/x/v2/view/like/triple"])
    }
    @Test func clientCoinReadsBackTotalAfterOneWrite() async throws {
        var writes = 0
        let api = BilibiliAPI(
            restoreSession: false,
            sessionConfiguration: config { request in
                switch request.url!.path {
                case "/x/web-interface/view": return try .json(["code": 0, "data": ["aid": 123]])
                case "/x/web-interface/archive/relation":
                    return try .json(["code": 0, "data": ["coin": writes == 0 ? 1 : 2]])
                case "/x/v2/view/coin/add":
                    writes += 1
                    return try .json(["code": 0])
                default:
                    Issue.record("unexpected endpoint")
                    throw URLError(.badURL)
                }
            })
        try await api.installClientLogin(login())
        #expect(try await api.coinVideo(bvid: "BV1234567890", count: 1) == 2)
        #expect(writes == 1)
    }
    @Test func cdnProbeSelectsValidBackupAndKeepsSourceMetadata() async throws {
        let transport = MediaRangeTransport(
            configuration: config { request in
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1023")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                if request.url?.host == "bad.bilivideo.com" {
                    return ExperienceResponse(status: 503)
                }
                return ExperienceResponse(
                    status: 206,
                    headers: ["Content-Range": "bytes 0-1023/2048", "Content-Type": "video/mp4"],
                    data: Data(repeating: 1, count: 1024))
            })
        let bad = URL(string: "https://bad.bilivideo.com/video")!
        let good = URL(string: "https://good.bilivideo.com/video")!
        let stream = PlaybackStream(
            urls: [bad, good], codec: "avc1", bandwidth: 1000, initialization: 0...10,
            index: 11...100)
        let source = Playback(
            url: bad, quality: "test", qualityID: 80, qualities: [], videoStream: stream,
            audioStream: nil)
        let result = await CDNSelector(transport: transport).select(source)
        #expect(result.url == good && result.videoStream?.urls == [good, bad])
        #expect(result.videoStream?.index == stream.index && result.qualityID == 80)
    }
    @Test func rangeRejectsFullResponsesAndIncorrectOffsets() async throws {
        for (status, range) in [(200, "bytes 0-3/4"), (206, "bytes 1-4/5")] {
            let transport = MediaRangeTransport(
                configuration: config { _ in
                    ExperienceResponse(
                        status: status, headers: ["Content-Range": range], data: Data([1, 2, 3, 4]))
                })
            defer { transport.close() }
            do {
                _ = try await transport.read(
                    URL(string: "https://upos-test.bilivideo.com/video")!, start: 0, length: 4)
                Issue.record("accepted invalid media range")
            } catch {}
        }
    }
    @Test func interruptedTransferPersistsPrefixAndResumesOnlyMissingBytes() async throws {
        let bytes = Data((0..<96).map(UInt8.init))
        var failing = true
        var starts: [Int] = []
        let transport = MediaRangeTransport(
            configuration: config { request in
                let range = (request.value(forHTTPHeaderField: "Range") ?? "").replacingOccurrences(
                    of: "bytes=", with: ""
                ).split(separator: "-").compactMap { Int($0) }
                let start = range[0]
                let end = min(95, range[1])
                starts.append(start)
                let headers = [
                    "Content-Range": "bytes \(start)-\(end)/96", "Content-Type": "video/mp4",
                ]
                if failing && end > 15 {
                    return ExperienceResponse(
                        status: 206, headers: headers, data: start == 0 ? bytes.prefix(32) : Data(),
                        failure: URLError(.networkConnectionLost))
                }
                return ExperienceResponse(
                    status: 206, headers: headers, data: bytes.subdata(in: start..<(end + 1)))
            })
        let transfer = ResumableMediaDownload(transport: transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://upos-test.bilivideo.com/video")!
        do {
            _ = try await transfer.download(
                urls: [url], codec: "test", indexEnd: 15, directory: directory
            ) { _ in }
            Issue.record("expected interrupted transfer")
        } catch {}
        let partial = try Data(contentsOf: directory.appendingPathComponent("piece-0.partial"))
        #expect(partial == bytes.prefix(32))
        failing = false
        starts = []
        let result = try await transfer.download(
            urls: [url], codec: "test", indexEnd: 15, directory: directory
        ) { _ in }
        #expect(try Data(contentsOf: result) == bytes)
        #expect(starts == [0, 32])
    }
    @Test func changedMediaDiscardsPreviousDownloadBeforeReusingPieces() async throws {
        var bytes = Data(repeating: 1, count: 64)
        let transport = MediaRangeTransport(
            configuration: config { request in
                let range = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(
                    separator: "-"
                ).compactMap { Int($0) }
                let start = range[0]
                let end = min(63, range[1])
                return ExperienceResponse(
                    status: 206,
                    headers: [
                        "Content-Range": "bytes \(start)-\(end)/64", "Content-Type": "video/mp4",
                    ], data: bytes.subdata(in: start..<(end + 1)))
            })
        let transfer = ResumableMediaDownload(transport: transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://upos-test.bilivideo.com/video")!
        _ = try await transfer.download(
            urls: [url], codec: "test", indexEnd: 15, directory: directory
        ) { _ in }
        bytes = Data(repeating: 2, count: 64)
        let result = try await transfer.download(
            urls: [url], codec: "test", indexEnd: 15, directory: directory
        ) { _ in }
        #expect(try Data(contentsOf: result) == bytes)
    }
    @Test func commentCardsOnlyAcceptVideoDomainsAndBoundTheirCount() {
        #expect(
            CommentVideoLinks.allowed("https://bilibili.com.evil.test/video/BV1234567890") == nil)
        #expect(CommentVideoLinks.allowed("https://user@bilibili.com/video/BV1234567890") == nil)
        #expect(CommentVideoLinks.allowed("https://bilibili.com:444/video/BV1234567890") == nil)
        #expect(
            CommentVideoLinks.parse(
                "BV1234567890 https://www.bilibili.com/video/BV1234567890?tracking=x https://b23.tv/abc https://b23.tv/def"
            ).count == 2)
        #expect(
            CommentVideoLinks.allowed("http://b23.tv/abc?tracking=x")?.absoluteString
                == "https://b23.tv/abc")
    }
    @Test func searchFiltersClampInputsAndUseStableDateBounds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SearchOptions(duration: 9, days: -1).parameters(now: now) == ["duration": "0"])
        #expect(
            SearchOptions(duration: 2, days: 1).parameters(now: now) == [
                "duration": "2", "pubtime_begin_s": "913600", "pubtime_end_s": "1000000",
            ])
    }
}
