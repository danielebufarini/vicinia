// Vicinia — native Apple Screen Sharing clipboard messages (wire grammar only).
// SPDX-License-Identifier: MIT
//
// Native pasteboard messages:
//   client → Mac  0x15 AutoPasteboard  `15 00 00 01 00 00 00 00` (selector 1 =
//                 start monitoring; the Mac then announces pasteboard changes)
//   client → Mac  0x0b ClipboardRequest `0b 00 00 00 00 00 00 00` (full data)
//   Mac → client  0x14 MiscStatus command 2: the Mac pasteboard changed
//   both ways     0x1f ClipboardSend: u8 0x1f | u8 0 | u8 promise | u8 0 |
//                 u32 reserved | u32 uncompressed | u32 compressed | zlib stream
// Observed Mac payloads end with a zlib sync flush, without a final block or
// trailer. Vicinia uses the same framing for outbound payloads.
// The inflated archive repeats, until its end, one item per pasteboard item:
//   u32 flavor_count, then per flavor: u32 type_len | type (UTI) | u32 reserved
//   | u32 tag_count | (u32 len | key | u32 len | value)×tag_count | u32 data_len | data
// A zero-length flavor is a promise without data. `public.utf16-plain-text`
// travels big-endian. An empty Mac pasteboard has uncompressed size 0.

import Foundation
import zlib

/// Engineering bounds, checked before the corresponding allocation.
struct ClipboardLimits: Equatable, Sendable {
    /// Largest Mac payload buffered; a larger one is skipped unread (bounded discard).
    var inboundCompressed = 4 << 20
    /// Inflated archive, either direction.
    var archive = 16 << 20
    var items = 64
    var flavorsPerItem = 64
    var flavors = 256
    var tagsPerFlavor = 16
    var nameBytes = 1024
    var tagBytes = 4096
    var imageDimension = 16_384
    var imagePixels = 50_000_000
    var imageFrames = 64

    static let standard = ClipboardLimits()
}

/// Why a clipboard payload was not used. Never carries content.
enum ClipboardIssue: Error, Equatable, Sendable {
    case empty
    case unsupported
    case malformed
    case tooLarge(bytes: Int, limit: Int)
    /// More pasteboard items than `limit` (a count, not a size).
    case tooManyItems(limit: Int)
    /// The local pasteboard offered content whose representations could not be loaded.
    case unreadable
}

enum ClipboardWire {
    /// The pasteboard maximum of the Mac's ScreensharingAgent: larger sizes are
    /// not native and fail the session as undelimitable framing.
    static let nativeMaximum = 100 << 20
    static let headerLength = 16

    static let autoPasteboardEnable: [UInt8] = [0x15, 0, 0, 1, 0, 0, 0, 0]
    static let request: [UInt8] = [0x0b, 0, 0, 0, 0, 0, 0, 0]
    static let pasteboardChangedStatus: UInt16 = 2

    struct Flavor: Equatable, Sendable {
        var type: String
        var data: [UInt8]
    }

    struct Item: Equatable, Sendable {
        var flavors: [Flavor]
    }

    struct Header: Equatable, Sendable {
        let promise: Bool
        let uncompressed: Int
        let compressed: Int

        init(_ b: [UInt8]) throws(ClipboardIssue) {
            guard b.count >= ClipboardWire.headerLength, b[0] == 0x1F else { throw .malformed }
            promise = b[2] & 1 != 0
            uncompressed = Int(b[8]) << 24 | Int(b[9]) << 16 | Int(b[10]) << 8 | Int(b[11])
            compressed = Int(b[12]) << 24 | Int(b[13]) << 16 | Int(b[14]) << 8 | Int(b[15])
        }
    }

    // MARK: Mac → client

    /// Decodes one complete 0x1f message (header and compressed payload).
    /// Sizes are checked against `limits` before inflation.
    static func decode(_ message: [UInt8], limits: ClipboardLimits = .standard) throws(ClipboardIssue) -> [Item] {
        let header = try Header(message)
        guard message.count == headerLength + header.compressed else { throw .malformed }
        guard header.compressed <= limits.inboundCompressed else {
            throw .tooLarge(bytes: header.compressed, limit: limits.inboundCompressed)
        }
        guard header.uncompressed <= limits.archive else { throw .tooLarge(bytes: header.uncompressed, limit: limits.archive) }
        guard header.uncompressed > 0 else { throw .empty }
        let archive = try inflate(Array(message[headerLength...]), exactly: header.uncompressed)
        let items = try parseArchive(archive, limits: limits)
        guard !items.isEmpty else { throw .empty }
        return items
    }

    /// Inflates a zlib stream that must produce exactly `size` bytes. Accepts
    /// the Mac's sync-flushed stream without a final block or trailer; rejects
    /// a stream that would produce more, or less, than declared.
    static func inflate(_ input: [UInt8], exactly size: Int) throws(ClipboardIssue) -> [UInt8] {
        guard size > 0, !input.isEmpty else { throw .malformed }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw .malformed }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: size + 1)   // one spare byte detects an overrun
        var input = input
        let status: Int32 = input.withUnsafeMutableBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
                stream.next_out = o.baseAddress; stream.avail_out = uInt(o.count)
                return zlib.inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR,
              Int(stream.total_out) == size, stream.avail_in == 0 else { throw .malformed }
        out.removeLast()
        return out
    }

    static func parseArchive(_ archive: [UInt8], limits: ClipboardLimits = .standard) throws(ClipboardIssue) -> [Item] {
        var r = ByteReader(archive)
        var items: [Item] = []
        var total = 0
        do {
            func counted(_ limit: Int) throws -> [UInt8] {
                let n = Int(try r.u32())
                guard n <= limit else { throw ClipboardIssue.malformed }
                return try r.take(n)
            }
            while r.remaining > 0 {
                guard items.count < limits.items else { throw ClipboardIssue.tooManyItems(limit: limits.items) }
                let count = Int(try r.u32())
                guard count <= limits.flavorsPerItem, total + count <= limits.flavors else { throw ClipboardIssue.malformed }
                total += count
                var item = Item(flavors: [])
                for _ in 0..<count {
                    guard let type = String(validating: try counted(limits.nameBytes), as: UTF8.self) else {
                        throw ClipboardIssue.malformed
                    }
                    _ = try r.u32()                                 // reserved
                    let tags = Int(try r.u32())
                    guard tags <= limits.tagsPerFlavor else { throw ClipboardIssue.malformed }
                    for _ in 0..<tags { _ = try counted(limits.nameBytes); _ = try counted(limits.tagBytes) }
                    let data = try counted(r.remaining)
                    var flavor = Flavor(type: type, data: data)
                    if type == "public.utf16-plain-text" { flavor.data = Self.swapUTF16(data) }
                    item.flavors.append(flavor)
                }
                items.append(item)
            }
        } catch let issue as ClipboardIssue {
            throw issue
        } catch {
            throw .malformed                                        // truncated field
        }
        return items
    }

    /// Big-endian (wire) and little-endian (iOS native) UTF-16 swap; odd lengths stay as they are.
    static func swapUTF16(_ data: [UInt8]) -> [UInt8] {
        guard data.count % 2 == 0 else { return data }
        var out = data
        for i in stride(from: 0, to: data.count, by: 2) { out.swapAt(i, i + 1) }
        return out
    }

    // MARK: client → Mac

    /// Builds one 0x1f message carrying full data (never promises, never empty).
    static func encode(_ items: [Item], limits: ClipboardLimits = .standard,
                       maxMessage: Int) throws(ClipboardIssue) -> [UInt8] {
        guard !items.isEmpty, items.allSatisfy({ !$0.flavors.isEmpty }) else { throw .empty }
        var archive = ByteWriter()
        for item in items {
            archive.u32(UInt32(item.flavors.count))
            for flavor in item.flavors {
                let type = Array(flavor.type.utf8)
                archive.u32(UInt32(type.count)); archive.append(type)
                archive.u32(0)                                      // reserved
                archive.u32(0)                                      // no tags
                let data = flavor.type == "public.utf16-plain-text" ? swapUTF16(flavor.data) : flavor.data
                guard archive.bytes.count + 4 + data.count <= limits.archive else {
                    throw .tooLarge(bytes: archive.bytes.count + 4 + data.count, limit: limits.archive)
                }
                archive.u32(UInt32(data.count)); archive.append(data)
            }
        }
        let compressed = try syncFlushDeflate(archive.bytes)
        guard headerLength + compressed.count <= maxMessage else {
            throw .tooLarge(bytes: headerLength + compressed.count, limit: maxMessage)
        }
        var w = ByteWriter(capacity: headerLength + compressed.count)
        w.u8(0x1F); w.u8(0); w.u8(0); w.u8(0)
        w.u32(0)
        w.u32(UInt32(archive.bytes.count)); w.u32(UInt32(compressed.count))
        w.append(compressed)
        return w.bytes
    }

    /// zlib header and deflate blocks ending in a sync flush (`00 00 ff ff`),
    /// with no final block and no Adler-32, matching observed Mac payloads.
    static func syncFlushDeflate(_ input: [UInt8]) throws(ClipboardIssue) -> [UInt8] {
        guard !input.isEmpty else { throw .empty }
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw .malformed
        }
        defer { deflateEnd(&stream) }
        // The bound of a complete stream also covers the flush marker that replaces its final block and trailer.
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 16)
        var input = input
        let status: Int32 = input.withUnsafeMutableBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
                stream.next_out = o.baseAddress; stream.avail_out = uInt(o.count)
                return zlib.deflate(&stream, Z_SYNC_FLUSH)
            }
        }
        // Output space left over: the flush is complete (zlib needs another call only when it ran out).
        guard status == Z_OK, stream.avail_in == 0, stream.avail_out > 0 else { throw .malformed }
        return Array(out.prefix(Int(stream.total_out)))
    }
}
