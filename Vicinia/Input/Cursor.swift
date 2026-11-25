// Vicinia — cursor STORE/SELECT handling with bounded inflation/cache,
// BGRA upload and last-valid unknown SELECT.
// SPDX-License-Identifier: MIT
import Foundation
import zlib

struct CursorImage: Sendable, Equatable {
    let width: Int, height: Int
    let hotspot: CGPoint
    let bgra: [UInt8]
    static let arrow: CursorImage = {
        let rows = ["X...........", "XX..........", "XOX.........", "XOOX........", "XOOOX.......", "XOOOOX......", "XOOOOOX.....", "XOOOOOOX....", "XOOOOOOOX...", "XOOOOXXXXX..", "XOOXOX......", "XOX.XOX.....", "XX..XOX.....", "X....XOX....", ".....XOX....", "......X....."]
        let bytes = rows.flatMap { $0.flatMap { c -> [UInt8] in c == "." ? [0,0,0,0] : c == "X" ? [0,0,0,255] : [255,255,255,255] } }
        return CursorImage(width: 12, height: 16, hotspot: .zero, bgra: bytes)
    }()
}

struct CursorCache {
    static let maxDimension = 256
    static let maxEntries = 64
    static let maxBytes = 4 << 20
    private(set) var images: [UInt32: CursorImage] = [:]
    private var order: [UInt32] = []
    private(set) var selected: CursorImage?
    private(set) var visible = true

    mutating func consume(_ rect: FramebufferRect) throws {
        var r = ByteReader(rect.body)
        let id = try r.u32(), size = Int(try r.u32())
        guard size == r.remaining else { throw WireError.invalid("cursor compressed length") }
        if size == 0 {
            if let image = images[id] { selected = image }
            visible = true
            return
        }
        let w = Int(rect.w), h = Int(rect.h)
        guard w > 0, h > 0, w <= Self.maxDimension, h <= Self.maxDimension,
              rect.x < rect.w, rect.y < rect.h, size <= 1 << 20 else { throw WireError.invalid("cursor bounds") }
        let count = w * h, expected = count * 5
        let compressed = try r.take(size)
        var raw = [UInt8](repeating: 0, count: expected + 1)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WireError.invalid("cursor inflate init")
        }
        defer { inflateEnd(&stream) }
        let status = compressed.withUnsafeBytes { src in
            raw.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(size)
                stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(expected + 1)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard (status == Z_OK || status == Z_STREAM_END), stream.total_out == expected, stream.avail_in == 0 else {
            throw WireError.invalid("cursor inflation length/status")
        }
        var bgra = Array(raw.prefix(count * 4))
        for i in 0..<count { bgra[i * 4 + 3] = raw[count * 4 + i] }
        let image = CursorImage(width: w, height: h, hotspot: CGPoint(x: Int(rect.x), y: Int(rect.y)), bgra: bgra)
        order.removeAll { $0 == id }
        images[id] = image; order.append(id)
        while images.count > Self.maxEntries || images.values.reduce(0, { $0 + $1.bgra.count }) > Self.maxBytes {
            images.removeValue(forKey: order.removeFirst())
        }
        selected = image; visible = true
    }
}

struct HostKeyboardStatus: Sendable {
    let source: String
    let flags: UInt32
    var secure: Bool { flags & 1 != 0 }
    init(_ body: [UInt8]) throws {
        var r = ByteReader(body)
        guard try r.u16() == 1 else { throw WireError.invalid("keyboard status version") }
        flags = try r.u32()
        let n = Int(try r.u16())
        guard n <= 1024, n == r.remaining, let s = String(bytes: try r.take(n), encoding: .utf8) else {
            throw WireError.invalid("keyboard source")
        }
        source = s
    }
}
