import CryptoKit
import Foundation

public actor ResumableMediaDownload {
    private let transport: MediaRangeTransport
    public init(transport: MediaRangeTransport = MediaRangeTransport()) {
        self.transport = transport
    }
    deinit { transport.close() }

    public func download(
        urls: [URL], codec: String, indexEnd: Int64 = 65_535, directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let candidates = Array(urls.filter(MediaURLPolicy.allows).prefix(3))
        guard !candidates.isEmpty, indexEnd >= 0, indexEnd < 1_048_576 else {
            throw APIError(code: -1, message: "没有可下载的媒体地址或索引过大")
        }
        var probe: MediaRangeResponse?
        var selected: URL?
        var lastError: Error = APIError(code: -1, message: "无法读取媒体")
        for url in candidates {
            do {
                probe = try await transport.read(url, start: 0, length: Int(indexEnd + 1))
                selected = url
                break
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        guard let probe, let selected else { throw lastError }
        let identity = SHA256.hash(data: Data("\(codec)|\(probe.total)|".utf8) + probe.data).map {
            String(format: "%02x", $0)
        }.joined()
        let marker = directory.appendingPathComponent("identity")
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path),
            (try? String(contentsOf: marker, encoding: .utf8)) != identity
        {
            try fm.removeItem(at: directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try identity.write(to: marker, atomically: true, encoding: .utf8)
        let assembled = directory.appendingPathComponent("complete.mp4")
        if Self.size(assembled) == probe.total {
            progress(1)
            return assembled
        }
        let pieceSize: Int64 = 4 * 1_048_576
        let count = Int((probe.total + pieceSize - 1) / pieceSize)
        let meter = TransferProgress(total: probe.total, update: progress)
        let ordered = [selected] + candidates.filter { $0 != selected }
        let transport = transport
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func schedule(_ index: Int) {
                let start = Int64(index) * pieceSize
                let length = min(pieceSize, probe.total - start)
                group.addTask {
                    try await Self.piece(
                        index: index, start: start, length: length, urls: ordered, anchor: probe,
                        transport: transport, directory: directory, meter: meter)
                }
            }
            for _ in 0..<min(2, count) {
                schedule(next)
                next += 1
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < count {
                    schedule(next)
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        let temporary = directory.appendingPathComponent("assembled.partial")
        fm.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        try output.truncate(atOffset: 0)
        defer { try? output.close() }
        for index in 0..<count {
            try Task.checkCancellation()
            let input = try FileHandle(
                forReadingFrom: directory.appendingPathComponent("piece-\(index)"))
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
        }
        try output.synchronize()
        guard Self.size(temporary) == probe.total else {
            throw APIError(code: -1, message: "下载文件长度不一致")
        }
        if fm.fileExists(atPath: assembled.path) { try fm.removeItem(at: assembled) }
        try fm.moveItem(at: temporary, to: assembled)
        return assembled
    }

    private static func piece(
        index: Int, start: Int64, length: Int64, urls: [URL], anchor: MediaRangeResponse,
        transport: MediaRangeTransport, directory: URL, meter: TransferProgress
    ) async throws {
        let complete = directory.appendingPathComponent("piece-\(index)")
        if size(complete) == length {
            await meter.set(index, bytes: length)
            return
        }
        let partial = complete.appendingPathExtension("partial")
        let fm = FileManager.default
        if size(partial) > length { try fm.removeItem(at: partial) }
        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: partial)
        var received = Int64(try file.seekToEnd())
        defer {
            try? file.synchronize()
            try? file.close()
        }
        await meter.set(index, bytes: received)
        var failures = 0
        var candidate = 0
        var verified: Set<URL> = [urls[0]]
        while received < length {
            try Task.checkCancellation()
            if let capacity = try? directory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]).volumeAvailableCapacityForImportantUsage, capacity < 64 * 1_048_576 {
                throw APIError(code: -1, message: "磁盘可用空间不足，已保留下载进度")
            }
            let url = urls[candidate % urls.count]
            do {
                if !verified.contains(url) {
                    let check = try await transport.read(url, start: 0, length: anchor.data.count)
                    guard check.total == anchor.total, check.data == anchor.data else {
                        throw APIError(code: -1, message: "备用线路的媒体内容不一致")
                    }
                    verified.insert(url)
                }
                let response: MediaRangeResponse
                do {
                    response = try await transport.read(
                        url, start: start + received, length: Int(min(1_048_576, length - received))
                    )
                } catch let partial as PartialMediaRead {
                    guard partial.response.total == anchor.total else {
                        throw APIError(code: -1, message: "媒体长度已变化")
                    }
                    try file.write(contentsOf: partial.response.data)
                    received += Int64(partial.response.data.count)
                    await meter.set(index, bytes: received)
                    throw URLError(.networkConnectionLost)
                }
                guard response.total == anchor.total else {
                    throw APIError(code: -1, message: "媒体长度已变化")
                }
                try file.write(contentsOf: response.data)
                received += Int64(response.data.count)
                await meter.set(index, bytes: received)
                failures = 0
            } catch {
                try Task.checkCancellation()
                failures += 1
                candidate += 1
                guard failures <= 3 else { throw error }
                try await Task.sleep(for: .milliseconds(250 * failures))
            }
        }
        try file.synchronize()
        if fm.fileExists(atPath: complete.path) { try fm.removeItem(at: complete) }
        try fm.moveItem(at: partial, to: complete)
    }
    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
    }
}

private actor TransferProgress {
    private let total: Int64
    private let update: @Sendable (Double) -> Void
    private var pieces: [Int: Int64] = [:]
    private var last = Date.distantPast
    init(total: Int64, update: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.update = update
    }
    func set(_ index: Int, bytes: Int64) {
        pieces[index] = bytes
        let received = pieces.values.reduce(0, +)
        if Date().timeIntervalSince(last) > 0.2 || received == total {
            last = Date()
            update(min(1, Double(received) / Double(total)))
        }
    }
}
