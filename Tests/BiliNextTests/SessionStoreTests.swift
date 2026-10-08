import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@Test func sessionRoundTripPreservesTabsAndPlayback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory.appendingPathComponent("nested"))
    let video = Video(bvid: "BV1234567890", title: "样例", author: "作者", historyCID: 42)
    try store.write([
        SessionTab(video: video, cid: 43, position: 123.5),
        SessionTab(video: Video(bvid: "BV0987654321", title: "另一个标签")),
    ])
    let restored = try store.read()
    #expect(restored.map(\.id) == ["BV1234567890", "BV0987654321"])
    #expect(restored[0].video == video)
    #expect(restored[0].cid == 43)
    #expect(restored[0].position == 123.5)
    #expect(restored[1].cid == nil)
    #expect(restored[1].position == 0)
    try store.write([])
    #expect(try store.read().isEmpty)
}

@Test func sessionReadsLegacyJSON() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = SessionStore(directory: directory)
    let fixture =
        #"[{"video":{"bvid":"BV1234567890","title":"旧标签","author":"作者"},"cid":42,"position":12.5}]"#
    try Data(fixture.utf8).write(to: store.file)
    let restored = try store.read()
    #expect(restored.first?.cid == 42)
    #expect(restored.first?.position == 12.5)
    #expect(restored.first?.video.title == "旧标签")
}

@Test func missingAndCorruptSessionKeepRecoveryEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory)
    #expect(throws: (any Error).self) { try store.read() }
    #expect(((try? store.read()) ?? []).isEmpty)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let corrupt = Data("invalid JSON".utf8)
    try corrupt.write(to: store.file)
    #expect(throws: (any Error).self) { try store.read() }
    #expect(((try? store.read()) ?? []).isEmpty)
    #expect(try Data(contentsOf: store.file) == corrupt)
}
