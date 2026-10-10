import Foundation

/// ISO BMFF sidx references locate fMP4 fragments without downloading the whole file.
struct DASHIndex {
    struct Fragment {
        let range: ClosedRange<Int64>
        let duration: Double
    }
    let fragments: [Fragment]

    init(data: Data, offset: Int64) throws {
        let bytes = [UInt8](data)
        var position = 0
        func number(_ start: Int, _ count: Int) throws -> UInt64 {
            guard start >= 0, start <= bytes.count - count else { throw Self.invalid() }
            return bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var result: [Fragment]?
        while position + 8 <= bytes.count {
            var size = Int(try number(position, 4))
            var header = 8
            if size == 1 {
                let large = try number(position + 8, 8)
                guard large <= UInt64(bytes.count) else { throw Self.invalid() }
                size = Int(large)
                header = 16
            }
            guard size >= header, size <= bytes.count - position else { throw Self.invalid() }
            if String(bytes: bytes[(position + 4)..<(position + 8)], encoding: .ascii) == "sidx" {
                let end = position + size
                var cursor = position + header
                let version = try number(cursor, 1)
                guard version <= 1 else { throw Self.invalid() }
                let scale = try number(cursor + 8, 4)
                guard scale > 0 else { throw Self.invalid() }
                cursor += 12
                let width = version == 0 ? 4 : 8
                // earliest_presentation_time remains in each fragment's tfdt timestamp.
                _ = try number(cursor, width)
                let firstOffset = try number(cursor + width, width)
                cursor += width * 2
                let count = Int(try number(cursor + 2, 2))
                cursor += 4
                guard count > 0, cursor + count * 12 <= end,
                    firstOffset <= UInt64(Int64.max), offset >= 0,
                    offset <= Int64.max - Int64(end),
                    Int64(firstOffset) <= Int64.max - offset - Int64(end)
                else { throw Self.invalid() }
                var start = offset + Int64(end) + Int64(firstOffset)
                var fragments: [Fragment] = []
                for _ in 0..<count {
                    let reference = try number(cursor, 4)
                    let duration = try number(cursor + 4, 4)
                    let length = Int64(reference & 0x7fff_ffff)
                    guard reference >> 31 == 0, length > 0, duration > 0,
                        length <= 32 * 1024 * 1024, start <= Int64.max - length
                    else { throw Self.invalid() }
                    fragments.append(
                        Fragment(
                            range: start...(start + length - 1),
                            duration: Double(duration) / Double(scale)))
                    start += length
                    cursor += 12
                }
                result = fragments
                break
            }
            position += size
        }
        guard let result else { throw Self.invalid() }
        fragments = result
    }

    func playlist(initializationPath: String, fragmentPath: (Int) -> String) -> String {
        let target = Int(ceil(fragments.map(\.duration).max() ?? 1))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(initializationPath)\"",
        ]
        for (index, fragment) in fragments.enumerated() {
            lines += [
                String(
                    format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"),
                    fragment.duration), fragmentPath(index),
            ]
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func invalid() -> NSError {
        NSError(
            domain: "BiliNext.DASH", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "媒体片段索引损坏或格式暂不支持"])
    }
}
