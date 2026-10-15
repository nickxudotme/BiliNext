import Foundation
import Testing

@testable import BiliNextCore

@Suite(.serialized)
struct FavoriteFolderTests {
    @Test func metadataUsesAttributeBitsAndPreservesSparseFields() throws {
        for (attr, privacy, isDefault) in [
            (0, 0, true), (1, 1, true), (22, 0, false), (23, 1, false),
        ] {
            let folder = try #require(
                BilibiliAPI.parseFavoriteFolder([
                    "id": "12342", "fid": 123, "mid": "42", "attr": attr, "title": "名称",
                    "media_count": 3,
                ]))
            #expect(folder.id == 12342 && folder.ownerID == 42 && folder.count == 3)
            #expect(folder.privacy == privacy && folder.isDefault == isDefault)
            #expect(folder.intro == nil && folder.cover == nil)
            var updated = folder
            updated.count += 1
            #expect(
                updated.attr == folder.attr && updated.ownerID == folder.ownerID
                    && updated.count == 4)
        }
        #expect(BilibiliAPI.parseFavoriteFolder(["id": true]) == nil)
        #expect(BilibiliAPI.parseFavoriteFolder(["id": 1.5]) == nil)
        #expect(BilibiliAPI.parseFavoriteFolder(["id": 0]) == nil)
        #expect(BilibiliAPI.parseFavoriteFolder(["fid": 123]) == nil)
        let unknown = try #require(BilibiliAPI.parseFavoriteFolder(["id": 12342]))
        #expect(unknown.privacy == nil && unknown.attr == nil && !unknown.isDefault)
    }

    @Test func createDefaultsToPrivateAndReturnsTheCompleteID() async throws {
        let fixture = FavoriteFolderFixture { _ in .success(["id": 98_765_442, "fid": 987654]) }
        defer { fixture.close() }
        let title = " 新 & + 收藏夹 "
        let created = try await fixture.api.createFavoriteFolder(title: title, expectedUserID: 42)
        #expect(created.id == 98_765_442 && created.title == title)
        #expect(created.privacy == 1 && !created.isDefault && created.ownerID == 42)
        let request = try #require(fixture.requests.first)
        #expect(request.url?.path == "/x/v3/fav/folder/add" && request.method == "POST")
        #expect(
            request.form == [
                "title": title, "intro": "", "cover": "", "privacy": "1", "csrf": "fixture-csrf",
            ])
        _ = try await fixture.api.createFavoriteFolder(title: "公开", privacy: 0, expectedUserID: 42)
        #expect(fixture.requests.last?.form["privacy"] == "0")
        #expect(fixture.requests.count == 2)
    }

    @Test func renameReadsCompleteMetadataAndPreservesDescriptionPrivacyAndCover() async throws {
        let intro = "保留描述 & 换行\n内容"
        let cover = "https://i0.hdslb.com/a%20b.jpg?x=a+b"
        let fixture = FavoriteFolderFixture { request in
            if request.url?.path == "/x/v3/fav/folder/info" {
                return .success([
                    "id": 12342, "mid": 42, "attr": 23, "intro": intro, "cover": cover,
                ])
            }
            return .success([:])
        }
        defer { fixture.close() }
        try await fixture.api.renameFavoriteFolder(id: 12342, title: "新 & 名称", expectedUserID: 42)
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests[0].method == "GET")
        #expect(fixture.requests[0].query == ["media_id": "12342"])
        #expect(fixture.requests[1].url?.path == "/x/v3/fav/folder/edit")
        #expect(
            fixture.requests[1].form == [
                "media_id": "12342", "title": "新 & 名称", "intro": intro, "cover": cover,
                "privacy": "1", "csrf": "fixture-csrf",
            ])
    }

    @Test func deletionUsesPluralMediaIDsWithoutConfusingFID() async throws {
        let fixture = FavoriteFolderFixture { request in
            request.method == "GET"
                ? .success(["id": 12342, "fid": 123, "mid": 42, "attr": 22]) : .success(0)
        }
        defer { fixture.close() }
        try await fixture.api.deleteFavoriteFolder(id: 12342, expectedUserID: 42)
        let deletion = try #require(fixture.requests.last)
        #expect(deletion.url?.path == "/x/v3/fav/folder/del" && deletion.method == "POST")
        #expect(deletion.form == ["media_ids": "12342", "csrf": "fixture-csrf"])
    }

    @Test func defaultForeignAndIncompleteFoldersNeverWrite() async throws {
        let cases: [[String: Any]] = [
            ["id": 12342, "mid": 42, "attr": 0, "intro": "", "cover": ""],
            ["id": 12342, "mid": 42, "attr": 1, "intro": "", "cover": ""],
            ["id": 12342, "mid": 99, "attr": 22, "intro": "", "cover": ""],
            ["id": 12342, "mid": 42, "intro": "", "cover": ""],
            ["id": 99942, "mid": 42, "attr": 22, "intro": "", "cover": ""],
        ]
        for data in cases {
            let fixture = FavoriteFolderFixture { _ in .success(data) }
            defer { fixture.close() }
            do {
                try await fixture.api.renameFavoriteFolder(
                    id: 12342, title: "名称", expectedUserID: 42)
                Issue.record("Expected editing to be rejected")
            } catch is APIError {}
            do {
                try await fixture.api.deleteFavoriteFolder(id: 12342, expectedUserID: 42)
                Issue.record("Expected deletion to be rejected")
            } catch is APIError {}
            #expect(fixture.requests.allSatisfy { $0.method == "GET" })
        }
        let sparse = FavoriteFolderFixture { _ in .success(["id": 12342, "mid": 42, "attr": 22]) }
        defer { sparse.close() }
        do {
            try await sparse.api.renameFavoriteFolder(id: 12342, title: "名称", expectedUserID: 42)
            Issue.record("Missing description and cover must not be replaced with empty values")
        } catch is APIError {}
        #expect(sparse.requests.count == 1)
    }

    @Test func accountChangeBetweenMetadataAndWriteStopsTheMutation() async throws {
        let fixture = FavoriteFolderFixture { _ in
            .success(["id": 12342, "mid": 42, "attr": 22, "intro": "", "cover": ""])
        }
        fixture.beforeResponse = { [weak fixture] _ in fixture?.setUser(99) }
        defer { fixture.close() }
        do {
            try await fixture.api.renameFavoriteFolder(id: 12342, title: "名称", expectedUserID: 42)
            Issue.record("Expected the changed account to stop the write")
        } catch let error as APIError {
            #expect(error.code == -101 && error.message == "账号已变化，请重新操作")
        }
        #expect(fixture.requests.count == 1 && fixture.requests.first?.method == "GET")
    }

    @Test func invalidInputAndWrongAccountNeverReachTheNetwork() async throws {
        let fixture = FavoriteFolderFixture { _ in .success([:]) }
        defer { fixture.close() }
        for (title, privacy, user) in [(" \n ", 1, Int64(42)), ("名称", 2, 42), ("名称", 1, 99)] {
            do {
                _ = try await fixture.api.createFavoriteFolder(
                    title: title, privacy: privacy, expectedUserID: user)
                Issue.record("Expected invalid input or account to fail locally")
            } catch is APIError {}
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func writeErrorsNeverRetryAndAcknowledgedCreateHasDistinctFailure() async throws {
        let failure = FavoriteFolderFixture { _ in .failure(-403) }
        defer { failure.close() }
        do {
            _ = try await failure.api.createFavoriteFolder(title: "名称", expectedUserID: 42)
            Issue.record("Expected the original write error")
        } catch let error as APIError { #expect(error.code == -403) }
        #expect(failure.requests.count == 1)
        failure.close()
        let acknowledged = FavoriteFolderFixture { _ in .success([:]) }
        defer { acknowledged.close() }
        do {
            _ = try await acknowledged.api.createFavoriteFolder(title: "名称", expectedUserID: 42)
            Issue.record("Expected an acknowledged-create result without an ID")
        } catch FavoriteFolderMutationError.createdWithoutIdentifier {}
        #expect(acknowledged.requests.count == 1)
    }

    @Test func folderListsAndPickerShareMetadataAndSavePinsAccount() async throws {
        let fixture = FavoriteFolderFixture { _ in
            .success([
                "list": [
                    [
                        "id": 12342, "mid": 42, "attr": 23, "title": "私密", "media_count": 7,
                        "fav_state": 1,
                    ]
                ]
            ])
        }
        defer { fixture.close() }
        let folders = try await fixture.api.favoriteFolders(mid: 42)
        let selections = try await fixture.api.favoriteSelection(mid: 42, aid: 100)
        #expect(selections.first?.folder == folders.first && selections.first?.selected == true)
        try await fixture.api.saveFavorites(aid: 100, add: [12342], remove: [], expectedUserID: 42)
        #expect(fixture.requests.last?.form["add_media_ids"] == "12342")
        fixture.setUser(99)
        do {
            try await fixture.api.saveFavorites(
                aid: 100, add: [12342], remove: [], expectedUserID: 42)
            Issue.record("Expected the changed account to stop saving favorites")
        } catch let error as APIError { #expect(error.code == -101) }
        #expect(fixture.requests.count == 3)
    }
}

private final class FavoriteFolderFixture: @unchecked Sendable {
    struct Record {
        let url: URL?
        let method: String
        let form: [String: String]
        let query: [String: String]
    }
    struct Response {
        let code: Int
        let data: Any
        static func success(_ data: Any) -> Self { Self(code: 0, data: data) }
        static func failure(_ code: Int) -> Self { Self(code: code, data: [:]) }
    }
    let api: BilibiliAPI
    private let jar: HTTPCookieStorage
    private let lock = NSLock()
    private var recorded: [Record] = []
    var requests: [Record] { lock.withLock { recorded } }
    var beforeResponse: ((Record) -> Void)?

    init(route: @escaping (Record) -> Response) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FavoriteFolderProtocol.self]
        jar = config.httpCookieStorage!
        api = BilibiliAPI(restoreSession: false, sessionConfiguration: config)
        setUser(42)
        jar.setCookie(
            HTTPCookie(properties: [
                .name: "bili_jct", .value: "fixture-csrf", .domain: ".bilibili.com", .path: "/",
                .secure: "TRUE",
            ])!)
        FavoriteFolderProtocol.install { [self] request, client in
            let form = Self.parameters(String(data: Self.body(request), encoding: .utf8) ?? "")
            let record = Record(
                url: request.url, method: request.httpMethod ?? "GET", form: form,
                query: Self.parameters(request.url?.query ?? ""))
            lock.withLock { recorded.append(record) }
            let response = route(record)
            beforeResponse?(record)
            client.respond(["code": response.code, "message": "fixture", "data": response.data])
        }
    }
    func setUser(_ id: Int64) {
        jar.setCookie(
            HTTPCookie(properties: [
                .name: "DedeUserID", .value: String(id), .domain: ".bilibili.com", .path: "/",
                .secure: "TRUE",
            ])!)
    }
    func close() { FavoriteFolderProtocol.install(nil) }
    private static func parameters(_ query: String) -> [String: String] {
        let items = URLComponents(string: "https://fixture/?" + query)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class FavoriteFolderProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest, FavoriteFolderProtocol) -> Void)?
    static func install(_ value: ((URLRequest, FavoriteFolderProtocol) -> Void)?) {
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
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
