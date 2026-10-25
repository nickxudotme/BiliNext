import Foundation
import Network
import Testing

@testable import BiliNext

@Test func sourceDurationDistinguishesACompleteShortTrackFromTruncatedBytes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func audio(seconds: Int) throws -> URL {
        let url = folder.appendingPathComponent("audio-\(seconds).m4a")
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = [
            "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", String(seconds), "-c:a", "aac", "-movflags", "+faststart", url.path,
        ]
        try encoder.run()
        encoder.waitUntilExit()
        try #require(encoder.terminationStatus == 0)
        return url
    }
    let complete = try audio(seconds: 6)
    let declaredTwenty = try audio(seconds: 20)
    let truncated = folder.appendingPathComponent("truncated.m4a")
    let bytes = try Data(contentsOf: declaredTwenty)
    try bytes.prefix(bytes.count / 3).write(to: truncated)
    let completeDuration = try #require(await MediaSourceDuration.load(complete))
    let truncatedDuration = try #require(await MediaSourceDuration.load(truncated))
    #expect(abs(completeDuration - 6) < 0.1)
    #expect(abs(truncatedDuration - 20) < 0.1)
}

@Test func cancellingAnInFlightSourceDurationProbeReturnsUnknown() async throws {
    let server = try HangingDurationSource()
    defer { server.stop() }
    let url = try await server.start()
    let probe = Task { await MediaSourceDuration.load(url) }
    for _ in 0..<100 where !server.accepted {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(server.accepted)
    probe.cancel()
    let result = await probe.value
    #expect(result == nil)
    let alreadyCancelled = Task { await MediaSourceDuration.load(url) }
    alreadyCancelled.cancel()
    let cancelledResult = await alreadyCancelled.value
    #expect(cancelledResult == nil)
}

private final class HangingDurationSource: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BiliNextTests.duration-source")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var accepted: Bool { lock.withLock { !connections.isEmpty } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            // Accept the local request but never return headers, keeping the
            // duration probe in flight until its task is cancelled.
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let port = try #require(listener.port)
        return URL(string: "http://127.0.0.1:\(port.rawValue)/audio.m4a")!
    }

    func stop() {
        listener.cancel()
        let held = lock.withLock { connections }
        for connection in held { connection.cancel() }
    }
}
