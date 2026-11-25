// Vicinia — bounded big-endian byte reading/writing for wire formats.
// SPDX-License-Identifier: MIT

import Foundation

enum WireError: Error, Equatable, CustomStringConvertible {
    case truncated(String)
    case invalid(String)

    var description: String {
        switch self {
        case .truncated(let w): "truncated \(w)"
        case .invalid(let w): "invalid \(w)"
        }
    }
}

/// Bounds-checked reader over a byte array; every read throws instead of trapping.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8(_ what: String = "u8") throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated(what) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16(_ what: String = "u16") throws -> UInt16 {
        let b = try take(2, what)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func u32(_ what: String = "u32") throws -> UInt32 {
        let b = try take(4, what)
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64(_ what: String = "u64") throws -> UInt64 {
        let b = try take(8, what)
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func i32(_ what: String = "i32") throws -> Int32 { Int32(bitPattern: try u32(what)) }

    mutating func take(_ n: Int, _ what: String = "bytes") throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw WireError.truncated(what) }
        defer { offset += n }
        return Array(bytes[offset ..< offset + n])
    }

    mutating func skip(_ n: Int, _ what: String = "bytes") throws {
        guard n >= 0, remaining >= n else { throw WireError.truncated(what) }
        offset += n
    }
}

/// Big-endian writer.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func append<C: Collection>(_ c: C) where C.Element == UInt8 { bytes += c }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Writes a big-endian u16/u32 at `offset` (array must be large enough).
    mutating func putU16(_ v: UInt16, at offset: Int) {
        self[offset] = UInt8(v >> 8); self[offset + 1] = UInt8(v & 0xFF)
    }

    mutating func putU32(_ v: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((v >> UInt32(24 - 8 * i)) & 0xFF) }
    }
}
