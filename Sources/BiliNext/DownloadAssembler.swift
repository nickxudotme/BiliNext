import AVFoundation
import CryptoKit
import Foundation

struct DownloadCheckpoint: Codable, Sendable {
    let bytes: Int64
    let digest: String
}

enum DownloadAssembler {
    static func prepare(video: URL, audio: URL?, output: URL) async throws -> DownloadCheckpoint {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        if let audio {
            let composition = AVMutableComposition()
            for (url, type) in [(video, AVMediaType.video), (audio, AVMediaType.audio)] {
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: type).first,
                    let target = composition.addMutableTrack(
                        withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw MPVError(message: "下载媒体缺少视频或音频轨道") }
                let duration = try await asset.load(.duration)
                try target.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            }
            guard
                let exporter = AVAssetExportSession(
                    asset: composition, presetName: AVAssetExportPresetPassthrough)
            else { throw MPVError(message: "无法创建合轨任务") }
            try await withTaskCancellationHandler {
                try await exporter.export(to: output, as: .mp4)
            } onCancel: {
                exporter.cancelExport()
            }
        } else {
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: video, to: output)
            }.value
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
            !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        else { throw MPVError(message: "下载文件未通过媒体检查") }
        let checkpoint = try await Task.detached(priority: .utility) { try fingerprint(output) }
            .value
        try JSONEncoder().encode(checkpoint).write(
            to: output.appendingPathExtension("json"), options: .atomic)
        return checkpoint
    }
    static func restore(_ output: URL) throws -> DownloadCheckpoint? {
        guard let data = try? Data(contentsOf: output.appendingPathExtension("json")),
            let checkpoint = try? JSONDecoder().decode(DownloadCheckpoint.self, from: data),
            let actual = try? fingerprint(output), actual.bytes == checkpoint.bytes,
            actual.digest == checkpoint.digest
        else { return nil }
        return checkpoint
    }
    static func publish(_ output: URL, destination: URL, checkpoint: DownloadCheckpoint) throws
        -> URL
    {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for number in 0..<100 {
            let target =
                number == 0
                ? destination
                : destination.deletingPathExtension().appendingPathExtension("\(number).mp4")
            if fm.fileExists(atPath: target.path) {
                if let actual = try? fingerprint(target), actual.bytes == checkpoint.bytes,
                    actual.digest == checkpoint.digest
                {
                    return target
                }
                continue
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString).partial")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: output, to: temporary)
            do {
                try fm.moveItem(at: temporary, to: target)
                return target
            } catch {
                if fm.fileExists(atPath: target.path) { continue }
                throw error
            }
        }
        throw MPVError(message: "无法找到可用的下载文件名")
    }
    static func fingerprint(_ file: URL) throws -> DownloadCheckpoint {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
            count += Int64(bytes.count)
        }
        return DownloadCheckpoint(
            bytes: count, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
