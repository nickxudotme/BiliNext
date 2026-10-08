import Foundation

public struct Danmaku: Identifiable, Sendable, Equatable {
    public let id: String
    public let time: Double
    public let mode: Int
    public let fontSize: Double
    public let color: UInt32
    public let text: String
    public init(
        id: String, time: Double, mode: Int, fontSize: Double = 25, color: UInt32 = 0xffffff,
        text: String
    ) {
        self.id = id
        self.time = time
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        self.text = text
    }
}

public enum DanmakuDecoder {
    // DmSegMobileReply.elems = 1; field numbers match PiliPlus's dm/v1 schema.
    public static func decode(_ data: Data) throws -> [Danmaku] {
        guard data.count <= 16 * 1024 * 1024 else { throw DecodeError.malformed }
        var reader = ProtoReader(bytes: Array(data))
        var result: [Danmaku] = []
        while !reader.ended {
            let tag = try reader.varint()
            if tag == 10 {
                var item = ProtoReader(bytes: try reader.block())
                var id: UInt64 = 0
                var time: UInt64 = 0
                var mode: UInt64 = 1
                var font: UInt64 = 25
                var color: UInt64 = 0xffffff
                var text = ""
                var idString = ""
                while !item.ended {
                    let field = try item.varint()
                    switch field {
                    case 8: id = try item.varint()
                    case 16: time = try item.varint()
                    case 24: mode = try item.varint()
                    case 32: font = try item.varint()
                    case 40: color = try item.varint()
                    case 58: text = String(decoding: try item.block(), as: UTF8.self)
                    case 98: idString = String(decoding: try item.block(), as: UTF8.self)
                    default: try item.skip(field & 7)
                    }
                }
                if !text.isEmpty, text.count <= 1000, time <= UInt64(Int32.max),
                    [1, 2, 3, 4, 5].contains(mode)
                {
                    result.append(
                        Danmaku(
                            id: idString.isEmpty ? String(id) : idString, time: Double(time) / 1000,
                            mode: Int(mode), fontSize: Double(min(64, max(12, font))),
                            color: UInt32(truncatingIfNeeded: color), text: text))
                }
            } else {
                try reader.skip(tag & 7)
            }
        }
        return result.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }
    enum DecodeError: Error { case malformed }
    private struct ProtoReader {
        let bytes: [UInt8]
        var index = 0
        var ended: Bool { index == bytes.count }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw DecodeError.malformed }
                let byte = bytes[index]
                index += 1
                if shift == 63 && byte > 1 { throw DecodeError.malformed }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw DecodeError.malformed
        }
        mutating func block() throws -> [UInt8] {
            let count = try varint()
            guard count <= UInt64(bytes.count - index) else { throw DecodeError.malformed }
            let end = index + Int(count)
            defer { index = end }
            return Array(bytes[index..<end])
        }
        mutating func skip(_ wire: UInt64) throws {
            switch wire {
            case 0: _ = try varint()
            case 1:
                guard bytes.count - index >= 8 else { throw DecodeError.malformed }
                index += 8
            case 2: _ = try block()
            case 5:
                guard bytes.count - index >= 4 else { throw DecodeError.malformed }
                index += 4
            default: throw DecodeError.malformed
            }
        }
    }
}

public struct DanmakuPlacement: Identifiable, Sendable {
    public var id: String { comment.id }
    public let comment: Danmaku
    public let lane: Int
    public let width: Double
    public let duration: Double
    public func visible(at time: Double) -> Bool {
        time >= comment.time && time < comment.time + duration
    }
    public func x(at time: Double, viewport: Double) -> Double {
        comment.mode == 4 || comment.mode == 5
            ? (viewport - width) / 2
            : viewport - (time - comment.time) * (viewport + width) / duration
    }
}

public enum DanmakuLayout {
    public static func arrange(
        _ comments: [Danmaku], viewport: Double, lanes: Int, duration: Double,
        width: (Danmaku) -> Double
    ) -> [DanmakuPlacement] {
        guard viewport > 0, lanes > 0, duration > 0 else { return [] }
        var scrolling = [DanmakuPlacement?](repeating: nil, count: lanes)
        var top = [Double](repeating: -.infinity, count: min(2, lanes))
        var bottom = top
        var result: [DanmakuPlacement] = []
        for comment in comments.sorted(by: {
            $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
        }) {
            let textWidth = max(1, width(comment))
            if comment.mode == 4 || comment.mode == 5 {
                let available = comment.mode == 4 ? bottom : top
                guard let lane = available.firstIndex(where: { $0 <= comment.time }) else {
                    continue
                }
                if comment.mode == 4 {
                    bottom[lane] = comment.time + 4
                } else {
                    top[lane] = comment.time + 4
                }
                result.append(
                    DanmakuPlacement(comment: comment, lane: lane, width: textWidth, duration: 4))
            } else {
                let speed = (viewport + textWidth) / duration
                guard
                    let lane = scrolling.firstIndex(where: { previous in
                        guard let previous else { return true }
                        let oldSpeed = (viewport + previous.width) / previous.duration
                        let clearedRight = previous.comment.time + (previous.width + 16) / oldSpeed
                        let noCatchUp =
                            previous.comment.time + previous.duration - (viewport - 16) / speed
                        return comment.time >= max(clearedRight, noCatchUp)
                    })
                else { continue }
                let placement = DanmakuPlacement(
                    comment: comment, lane: lane, width: textWidth, duration: duration)
                scrolling[lane] = placement
                result.append(placement)
            }
        }
        return result
    }
}
