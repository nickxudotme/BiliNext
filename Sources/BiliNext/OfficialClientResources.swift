import Foundation

enum OfficialClientResources {
    /// Read the installed client's ASAR without modifying it or bundling its code.
    static func playerCore() throws -> String {
        let url = URL(fileURLWithPath: "/Applications/哔哩哔哩.app/Contents/Resources/app.asar")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func uint32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= data.count else { throw ResourceError.invalidArchive }
            return Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
        let headerSize = try uint32(4)
        let jsonSize = try uint32(12)
        guard headerSize >= 8, jsonSize > 0, 16 + jsonSize <= data.count, jsonSize <= headerSize - 8 else { throw ResourceError.invalidArchive }
        let root = try JSONSerialization.jsonObject(with: data.subdata(in: 16..<16 + jsonSize)) as? [String: Any]
        var entry = root
        for name in ["render", "assets", "lib", "core.js"] {
            entry = (entry?["files"] as? [String: [String: Any]])?[name]
        }
        guard let entry, let offsetText = entry["offset"] as? String, let offset = Int(offsetText), let count = entry["size"] as? Int else { throw ResourceError.missingCore }
        guard headerSize <= data.count - 8, offset >= 0, offset <= data.count - 8 - headerSize else { throw ResourceError.invalidArchive }
        let start = 8 + headerSize + offset
        guard count > 0, start >= 0, start <= data.count, count <= data.count - start, let script = String(data: data.subdata(in: start..<start + count), encoding: .utf8) else { throw ResourceError.invalidArchive }
        guard script.contains("@metadata nano:"), script.contains("createPlayer") else { throw ResourceError.missingCore }
        return script
    }
    enum ResourceError: LocalizedError {
        case invalidArchive, missingCore
        var errorDescription: String? { "无法读取本机官方客户端的播放器核心，请确认已安装兼容版本的哔哩哔哩客户端。" }
    }
}
