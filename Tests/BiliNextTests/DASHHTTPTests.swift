import Foundation
import Testing

@testable import BiliNext

private final class RangeFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        let response = HTTPURLResponse(
            url: request.url!, statusCode: mode == "ignored" ? 200 : 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 100-103/1000", "Content-Length": "4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self, didLoad: mode == "overflow" ? Data(repeating: 1, count: 8) : Data([1, 2, 3, 4]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func mediaHTTPValidatesRangesBeforeAcceptingBodies() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeFixtureProtocol.self]
    let client = DASHHTTPClient(configuration: configuration)
    defer { client.invalidateAndCancel() }
    let valid = URLRequest(url: URL(string: "https://fixture.invalid/valid")!)
    #expect(try await client.data(for: valid, range: 100...103) == Data([1, 2, 3, 4]))
    let ignored = URLRequest(url: URL(string: "https://fixture.invalid/ignored")!)
    await #expect(throws: (any Error).self) {
        try await client.data(for: ignored, range: 100...103)
    }
    await #expect(throws: (any Error).self) { try await client.data(for: valid, range: 0...3) }
    let overflow = URLRequest(url: URL(string: "https://fixture.invalid/overflow")!)
    await #expect(throws: (any Error).self) {
        try await client.data(for: overflow, range: 100...103)
    }
}
