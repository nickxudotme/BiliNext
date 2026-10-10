import AVFoundation
import BiliNextCore
import Foundation
import Network

/// Exposes indexed, independently fetched fMP4 fragments to AVPlayer as local VOD HLS.
/// The listener is loopback-only; opaque paths map to fixed media sources, never arbitrary URLs.
final class DASHResourceLoader: @unchecked Sendable {
    private struct Track {
        let stream: PlaybackStream
        let index: DASHIndex
    }
    private let queue = DispatchQueue(label: "me.nickxu.BiliNext.dash")
    private let token = UUID().uuidString
    private let session: DASHHTTPClient
    private let listener: NWListener
    private let video: Track
    private let audio: Track?
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var startup: CheckedContinuation<URL, Error>?

    private init(video: Track, audio: Track?, session: DASHHTTPClient) throws {
        self.video = video
        self.audio = audio
        self.session = session
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func prepare(_ playback: Playback) async throws -> (DASHResourceLoader, AVPlayerItem) {
        guard let source = playback.videoStream else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        let session = DASHHTTPClient(configuration: configuration)
        do {
            async let video = track(source, session: session)
            async let audio = optionalTrack(playback.audioStream, session: session)
            let loader = try await DASHResourceLoader(video: video, audio: audio, session: session)
            do {
                let url = try await loader.start()
                try Task.checkCancellation()
                return (loader, AVPlayerItem(url: url))
            } catch {
                loader.invalidate()
                throw error
            }
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    private static func optionalTrack(_ stream: PlaybackStream?, session: DASHHTTPClient)
        async throws
        -> Track?
    {
        guard let stream else { return nil }
        return try await track(stream, session: session)
    }

    private static func track(_ stream: PlaybackStream, session: DASHHTTPClient) async throws
        -> Track
    {
        let bytes = try await fetch(stream, range: stream.index, session: session)
        return try Track(
            stream: stream, index: DASHIndex(data: bytes, offset: stream.index.lowerBound))
    }

    private static func fetch(
        _ stream: PlaybackStream, range: ClosedRange<Int64>, session: DASHHTTPClient
    ) async throws -> Data {
        let length = range.upperBound - range.lowerBound + 1
        guard length > 0, length <= 32 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var failure: Error = URLError(.cannotLoadFromNetwork)
        for url in stream.urls {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            do {
                // Inspect headers before receiving the body: a CDN ignoring Range must not
                // turn a fragment request into an unbounded whole-video download.
                let data = try await session.data(for: request, range: range)
                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        throw failure
    }

    private func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    startup = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener.port else { return }
                            self.startup?.resume(
                                returning: URL(
                                    string:
                                        "http://127.0.0.1:\(port.rawValue)/\(self.token)/master.m3u8"
                                )!)
                            self.startup = nil
                        case .failed(let error):
                            self.startup?.resume(throwing: error)
                            self.startup = nil
                            self.invalidate()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, let pending = self.startup else { return }
                        self.startup = nil
                        pending.resume(throwing: URLError(.timedOut))
                        self.invalidate()
                    }
                }
            }
        } onCancel: {
            self.invalidate()
        }
    }

    func invalidate() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            startup?.resume(throwing: CancellationError())
            startup = nil
            listener.cancel()
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            session.invalidateAndCancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 12 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(id) }
            if case .cancelled = state { self?.finish(id) }
        }
        receive(connection, id: id, buffered: Data())
        queue.asyncAfter(deadline: .now() + 40) { [weak self] in self?.finish(id) }
    }

    private func finish(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] bytes, _, complete, error in
            guard let self, !self.stopped else { return }
            let data = buffered + (bytes ?? Data())
            guard data.count <= 8192, error == nil else {
                self.finish(id)
                return
            }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                self.tasks[id] = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
                            throw URLError(.badURL)
                        }
                        let (body, type) = try await self.response(path: String(parts[1]))
                        try Task.checkCancellation()
                        let header =
                            "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
                        var output = Data(header.utf8)
                        if parts[0] == "GET" { output.append(body) }
                        self.send(output, connection: connection, id: id)
                    } catch {
                        let output = Data(
                            "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                .utf8)
                        self.send(output, connection: connection, id: id)
                    }
                }
            } else if complete {
                self.finish(id)
            } else {
                self.receive(connection, id: id, buffered: data)
            }
        }
    }

    private func send(_ data: Data, connection: NWConnection, id: UUID) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.connections[id] != nil else { return }
            connection.send(
                content: data, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
        }
    }

    private func response(path: String) async throws -> (Data, String) {
        let root = "/\(token)/"
        guard path.hasPrefix(root) else { throw URLError(.badURL) }
        let relative = String(path.dropFirst(root.count))
        if relative == "master.m3u8" {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
            var attributes =
                "BANDWIDTH=\(max(1, video.stream.bandwidth + (audio?.stream.bandwidth ?? 0)))"
            let codecs = [video.stream.codec, audio?.stream.codec].compactMap { $0 }.joined(
                separator: ",")
            attributes += ",CODECS=\"\(codecs)\""
            if audio != nil {
                lines.append(
                    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"原声\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\""
                )
                attributes += ",AUDIO=\"audio\""
            }
            lines += ["#EXT-X-STREAM-INF:\(attributes)", "video.m3u8"]
            return (
                Data((lines.joined(separator: "\n") + "\n").utf8), "application/vnd.apple.mpegurl"
            )
        }
        for (name, track) in [("video", Optional(video)), ("audio", audio)] {
            guard let track else { continue }
            if relative == "\(name).m3u8" {
                let playlist = track.index.playlist(initializationPath: "\(name)/init.mp4") {
                    "\(name)/\($0).m4s"
                }
                return (Data(playlist.utf8), "application/vnd.apple.mpegurl")
            }
            if relative == "\(name)/init.mp4" {
                return (
                    try await Self.fetch(
                        track.stream, range: track.stream.initialization, session: session),
                    "video/mp4"
                )
            }
            if relative.hasPrefix("\(name)/"), relative.hasSuffix(".m4s"),
                let index = Int(relative.dropFirst(name.count + 1).dropLast(4)),
                track.index.fragments.indices.contains(index)
            {
                return (
                    try await Self.fetch(
                        track.stream, range: track.index.fragments[index].range, session: session),
                    "video/mp4"
                )
            }
        }
        throw URLError(.badURL)
    }
}
