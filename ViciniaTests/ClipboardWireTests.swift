// Vicinia tests — native clipboard wire grammar, parser bounds and the
// representation adapter. Fixtures are synthetic and non-sensitive;
// the Mac-shaped archive follows the native flavor layout and the Mac's
// sync-flushed zlib framing. These tests do not establish native support.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import UIKit
import zlib
@testable import Vicinia

enum ClipboardFixture {
    struct Flavor { let type: String; let tags: [(String, String)]; let data: [UInt8] }

    /// Archive as the Mac writes it: per item a flavor count, then per flavor
    /// type, reserved, tags and data (UTF-16 already big-endian in `data`).
    static func archive(_ items: [[Flavor]]) -> [UInt8] {
        var w = ByteWriter()
        func counted(_ bytes: [UInt8]) { w.u32(UInt32(bytes.count)); w.append(bytes) }
        for item in items {
            w.u32(UInt32(item.count))
            for flavor in item {
                counted(Array(flavor.type.utf8)); w.u32(0); w.u32(UInt32(flavor.tags.count))
                for (key, value) in flavor.tags { counted(Array(key.utf8)); counted(Array(value.utf8)) }
                counted(flavor.data)
            }
        }
        return w.bytes
    }

    /// zlib header + deflate blocks ending in a sync flush (the Mac's framing), or a complete stream.
    static func deflate(_ input: [UInt8], syncFlushOnly: Bool = true) -> [UInt8] {
        var stream = z_stream()
        _ = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        var input = input
        input.withUnsafeMutableBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
                stream.next_out = o.baseAddress; stream.avail_out = uInt(o.count)
                _ = zlib.deflate(&stream, syncFlushOnly ? Z_SYNC_FLUSH : Z_FINISH)
            }
        }
        return Array(out.prefix(Int(stream.total_out)))
    }

    static func message(archive: [UInt8], compressed: [UInt8]? = nil, declared: Int? = nil, promise: Bool = false) -> [UInt8] {
        let payload = compressed ?? (archive.isEmpty ? deflate([]) : deflate(archive))
        var w = ByteWriter()
        w.u8(0x1F); w.u8(0); w.u8(promise ? 1 : 0); w.u8(0); w.u32(0)
        w.u32(UInt32(declared ?? archive.count)); w.u32(UInt32(payload.count))
        w.append(payload)
        return w.bytes
    }

    static let sampleText = "Riga 1: àèìòù — 日本語 — 👩🏽‍💻\r\nRiga 2\n\tfine"

    /// One copied text as the Mac offers it: UTF-8, traditional Mac text and
    /// big-endian UTF-16, each with the aliases the Mac attaches.
    static func macText(_ text: String = sampleText) -> [Flavor] {
        [Flavor(type: "public.utf8-plain-text",
                tags: [("com.apple.ostype", "utf8"), ("com.apple.nspboard-type", "NSStringPboardType"),
                       ("public.mime-type", "text/plain;charset=utf-8")], data: Array(text.utf8)),
         Flavor(type: "com.apple.traditional-mac-plain-text", tags: [("com.apple.ostype", "TEXT")],
                data: Array("Riga".utf8)),
         Flavor(type: "public.utf16-plain-text", tags: [("com.apple.ostype", "utxt")],
                data: text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })]
    }

    static func item(_ entries: [String: [UInt8]]) -> ClipboardItem { entries.mapValues { Data($0) } }

    static func png(width: Int = 4, height: Int = 3) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A PNG of random pixels: it does not compress.
    static func noisePNG(side: Int) -> Data {
        var pixels = (0..<(side * side * 4)).map { _ in UInt8.random(in: 0...255) }
        let image = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        return UIImage(cgImage: image!).pngData()!
    }

    /// The same PNG whose header claims other dimensions (CRC kept valid): a decode bomb.
    static func pngClaiming(width: UInt32, height: UInt32) -> Data {
        var bytes = [UInt8](png())
        bytes.putU32(width, at: 16); bytes.putU32(height, at: 20)
        let crc = bytes[12 ..< 29].withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
        bytes.putU32(crc, at: 29)
        return Data(bytes)
    }
}

@Suite("Clipboard wire grammar")
struct ClipboardWireTests {
    typealias F = ClipboardFixture

    @Test func requestAndMonitoringMessagesAreExactlyTheNativeBytes() {
        #expect(ClipboardWire.request == [0x0B, 0, 0, 0, 0, 0, 0, 0])
        #expect(ClipboardWire.autoPasteboardEnable == [0x15, 0, 0, 1, 0, 0, 0, 0])
        #expect(ClipboardWire.pasteboardChangedStatus == 2)
    }

    @Test func macShapedThreeFlavorTextDecodesToExactUnicodeText() throws {
        let message = F.message(archive: F.archive([F.macText()]))
        let items = try ClipboardWire.decode(message)
        #expect(items.count == 1 && items[0].flavors.map(\.type)
                == ["public.utf8-plain-text", "com.apple.traditional-mac-plain-text", "public.utf16-plain-text"])
        let local = try ClipboardFormats.inbound(items)
        #expect(local == [[ClipboardFormats.text: Data(F.sampleText.utf8)]])
    }

    @Test func utf16AloneIsAnExplicitTextFallback() throws {
        let utf16 = F.macText()[2]
        let local = try ClipboardFormats.inbound(try ClipboardWire.decode(F.message(archive: F.archive([[utf16]]))))
        #expect(local == [[ClipboardFormats.text: Data(F.sampleText.utf8)]])
    }

    @Test func completeAndSyncFlushedStreamsBothInflate() throws {
        let archive = F.archive([F.macText()])
        for syncOnly in [true, false] {
            let message = F.message(archive: archive, compressed: F.deflate(archive, syncFlushOnly: syncOnly))
            #expect(try ClipboardWire.decode(message).count == 1)
        }
    }

    @Test func emptyMacPasteboardIsEmptyNotAnError() {
        #expect(throws: ClipboardIssue.empty) { try ClipboardWire.decode(F.message(archive: [])) }
    }

    @Test func declaredArchiveBeyondTheLimitIsRefusedBeforeInflation() {
        let limit = ClipboardLimits.standard.archive
        // Not even a zlib stream: refused by its declared size, never inflated.
        let message = F.message(archive: [], compressed: [UInt8](repeating: 0xEE, count: 64), declared: limit + 1)
        #expect(throws: ClipboardIssue.tooLarge(bytes: limit + 1, limit: limit)) { try ClipboardWire.decode(message) }
    }

    @Test func decompressionBombThatLiesAboutItsSizeIsMalformed() {
        let bomb = [UInt8](repeating: 0, count: 8 << 20)     // 8 MiB of zeros deflate to a few kilobytes
        let compressed = F.deflate(bomb)
        #expect(compressed.count < 64 << 10)
        let message = F.message(archive: [], compressed: compressed, declared: 1024)
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.decode(message) }
    }

    @Test func compressedPayloadBeyondTheInboundBoundIsTooLarge() {
        var limits = ClipboardLimits.standard
        limits.inboundCompressed = 32
        let archive = F.archive([F.macText()])
        #expect(throws: ClipboardIssue.self) { try ClipboardWire.decode(F.message(archive: archive), limits: limits) }
    }

    @Test(arguments: [0, 15, 17])
    func truncatedOrMisframedMessagesAreMalformed(_ cut: Int) {
        let message = F.message(archive: F.archive([F.macText()]))
        let broken: [UInt8] = switch cut {
        case 0: Array(message.dropLast())                     // payload shorter than declared
        case 15: Array(message.prefix(15))                    // header truncated
        default: message + [0]                                // longer than declared
        }
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.decode(broken) }
    }

    @Test func truncatedOrTrailingStreamsAreMalformed() {
        let archive = F.archive([F.macText()])
        let complete = F.deflate(archive, syncFlushOnly: false)
        #expect(throws: ClipboardIssue.malformed) {
            try ClipboardWire.decode(F.message(archive: archive, compressed: Array(complete.prefix(complete.count / 2))))
        }
        #expect(throws: ClipboardIssue.malformed) {
            try ClipboardWire.decode(F.message(archive: archive, compressed: complete + [1, 2, 3]))
        }
        #expect(throws: ClipboardIssue.malformed) {
            try ClipboardWire.decode(F.message(archive: archive, declared: archive.count + 1))
        }
    }

    @Test func archiveFieldsBeyondTheirBoundsAreMalformed() {
        let limits = ClipboardLimits.standard
        func flavors(_ n: Int) -> [F.Flavor] { (0..<n).map { F.Flavor(type: "public.utf8-plain-text", tags: [], data: Array("\($0)".utf8)) } }
        var tooManyItems = F.archive((0...limits.items).map { _ in flavors(1) })
        // An item count beyond the bound has a dedicated error for the reported limit.
        #expect(throws: ClipboardIssue.tooManyItems(limit: limits.items)) { try ClipboardWire.parseArchive(tooManyItems) }
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.parseArchive(F.archive([flavors(limits.flavorsPerItem + 1)])) }
        let longName = F.Flavor(type: String(repeating: "x", count: limits.nameBytes + 1), tags: [], data: [1])
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.parseArchive(F.archive([[longName]])) }
        let tags = F.Flavor(type: "public.html", tags: Array(repeating: ("k", "v"), count: limits.tagsPerFlavor + 1), data: [1])
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.parseArchive(F.archive([[tags]])) }
        // A data length beyond the archive, and a type that is not UTF-8.
        tooManyItems = F.archive([flavors(1)])
        tooManyItems.putU32(0x7FFF_FFFF, at: tooManyItems.count - 5)
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.parseArchive(tooManyItems) }
        var badName = F.archive([[F.Flavor(type: "ab", tags: [], data: [1])]])
        badName[8] = 0xFF
        #expect(throws: ClipboardIssue.malformed) { try ClipboardWire.parseArchive(badName) }
    }

    @Test func promisesAloneAreUnsupported() throws {
        let promised = F.archive([[F.Flavor(type: "public.utf8-plain-text", tags: [], data: []),
                                   F.Flavor(type: "public.png", tags: [], data: [])]])
        let items = try ClipboardWire.decode(F.message(archive: promised, promise: true))
        #expect(throws: ClipboardIssue.unsupported) { try ClipboardFormats.inbound(items) }
    }

    @Test func encodedMessageHasTheNativeHeaderAndRoundTrips() throws {
        let items = [ClipboardWire.Item(flavors: [.init(type: ClipboardFormats.text, data: Array(F.sampleText.utf8)),
                                                  .init(type: ClipboardFormats.html, data: Array("<b>x</b>".utf8))]),
                     ClipboardWire.Item(flavors: [.init(type: ClipboardFormats.url, data: Array("https://example.com/a?b=c".utf8))])]
        let message = try ClipboardWire.encode(items, maxMessage: HPSSSession.accessoryBudget)
        let header = try ClipboardWire.Header(message)
        #expect(Array(message.prefix(8)) == [0x1F, 0, 0, 0, 0, 0, 0, 0])
        #expect(!header.promise && header.compressed == message.count - 16)
        #expect(header.uncompressed == ClipboardFixture.archive(items.map { $0.flavors.map { F.Flavor(type: $0.type, tags: [], data: $0.data) } }).count)
        #expect(try ClipboardWire.decode(message) == items)
    }

    @Test func encodingRefusesEmptyAndOversizeContent() {
        #expect(throws: ClipboardIssue.empty) { try ClipboardWire.encode([], maxMessage: 1 << 20) }
        let noise = (0..<(64 << 10)).map { _ in UInt8.random(in: 0...255) }
        #expect(throws: ClipboardIssue.self) {
            try ClipboardWire.encode([.init(flavors: [.init(type: ClipboardFormats.html, data: noise)])], maxMessage: 16 << 10)
        }
    }
}

@Suite("Clipboard control parsing")
struct ClipboardParsingTests {
    @Test func clipboardWithinTheBoundIsDeliveredWholeAcrossRecords() throws {
        let message = ClipboardFixture.message(archive: ClipboardFixture.archive([ClipboardFixture.macText()]))
        guard case .needMore = try ServerMessageParser.parse(Array(message.prefix(message.count - 1))) else {
            Issue.record("a partial 0x1f must wait for more"); return
        }
        guard case .complete(.clipboardSend(let delivered), let consumed) = try ServerMessageParser.parse(message + [0x02]) else {
            Issue.record("expected one complete clipboard message"); return
        }
        #expect(delivered == message && consumed == message.count)
    }

    @Test func oversizeClipboardIsDiscardedNotFatal() throws {
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0x1F
        let size = ServerMessageParser.inboundClipboard + 1
        header.putU32(UInt32(size), at: 12)
        guard case .discard(.clipboardOversize(let compressed), let consumed, let skip) = try ServerMessageParser.parse(header) else {
            Issue.record("expected the bounded discard path"); return
        }
        #expect(compressed == size && consumed == 16 && skip == size)
    }

    @Test func clipboardBeyondTheNativeMaximumIsUndelimitable() {
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0x1F
        header.putU32(UInt32(ClipboardWire.nativeMaximum + 1), at: 12)
        #expect(throws: WireError.invalid("clipboard length")) { _ = try ServerMessageParser.parse(header) }
    }
}

@Suite("Clipboard representations")
struct ClipboardFormatTests {
    typealias F = ClipboardFixture

    private func roundTrip(_ local: [ClipboardItem]) throws -> [ClipboardItem] {
        let message = try ClipboardWire.encode(try ClipboardFormats.outbound(local), maxMessage: HPSSSession.accessoryBudget)
        return try ClipboardFormats.inbound(try ClipboardWire.decode(message))
    }

    @Test func unicodeTextAndLineBreaksRoundTripByteForByte() throws {
        let text = F.sampleText + "\r\r\n\u{2028}\u{0301}e\u{0301}"
        #expect(try roundTrip([[ClipboardFormats.text: Data(text.utf8)]]) == [[ClipboardFormats.text: Data(text.utf8)]])
        // Other local text spellings become UTF-8 text.
        #expect(try ClipboardFormats.outbound([["public.plain-text": Data("x".utf8)]]).first?.flavors.map(\.type) == [ClipboardFormats.text])
    }

    @Test func urlsTravelWithTextAndFileURLsAreNeverShared() throws {
        let link = "https://example.com/path?q=%C3%A0#frag"
        let shared = try roundTrip([[ClipboardFormats.url: Data(link.utf8)]])
        #expect(shared == [[ClipboardFormats.url: Data(link.utf8), ClipboardFormats.text: Data(link.utf8)]])
        #expect(throws: ClipboardIssue.unsupported) {
            try ClipboardFormats.outbound([["public.file-url": Data("file:///etc/hosts".utf8)]])
        }
        #expect(throws: ClipboardIssue.unsupported) {
            try ClipboardFormats.inbound([.init(flavors: [.init(type: ClipboardFormats.url, data: Array("file:///var/empty".utf8))])])
        }
    }

    @Test func richTextAndHtmlKeepTheirBytesAndTextFallback() throws {
        let rtf = Data("{\\rtf1\\ansi {\\b bold} àè}".utf8), html = Data("<p><b>bold</b> àè</p>".utf8)
        let local: ClipboardItem = [ClipboardFormats.rtf: rtf, ClipboardFormats.html: html, ClipboardFormats.text: Data("bold àè".utf8)]
        #expect(try roundTrip([local]) == [local])
        #expect(throws: ClipboardIssue.unsupported) { try ClipboardFormats.outbound([[ClipboardFormats.rtf: Data("not rtf".utf8)]]) }
    }

    @Test func validImagesKeepTheirOriginalBytes() throws {
        let png = F.png()
        #expect(try roundTrip([["public.png": png]]) == [["public.png": png]])
    }

    @Test func imageBombsAndMislabeledImagesAreRejectedFromTheHeaderAlone() {
        let limits = ClipboardLimits.standard
        #expect(ClipboardFormats.validImage(F.png(), type: "public.png", limits: limits))
        #expect(!ClipboardFormats.validImage(F.pngClaiming(width: 100_000, height: 100_000), type: "public.png", limits: limits))
        #expect(!ClipboardFormats.validImage(F.pngClaiming(width: 16_000, height: 16_000), type: "public.png", limits: limits))
        #expect(!ClipboardFormats.validImage(F.png(), type: "public.jpeg", limits: limits))
        #expect(!ClipboardFormats.validImage(Data("not an image".utf8), type: "public.png", limits: limits))
        #expect(throws: ClipboardIssue.unsupported) {
            try ClipboardFormats.inbound([.init(flavors: [.init(type: "public.png", data: [UInt8](F.pngClaiming(width: 100_000, height: 100_000)))])])
        }
    }

    @Test func unsupportedEmptyAndOversizeLocalContentAreDistinguished() {
        #expect(throws: ClipboardIssue.empty) { try ClipboardFormats.outbound([]) }
        #expect(throws: ClipboardIssue.empty) { try ClipboardFormats.outbound([[:]]) }
        #expect(throws: ClipboardIssue.unsupported) {
            try ClipboardFormats.outbound([["com.apple.flat-rtfd": Data([1]), "dyn.ah62d4rv4gu8y": Data([2])]])
        }
        var limits = ClipboardLimits.standard
        limits.archive = 8
        #expect(throws: ClipboardIssue.tooLarge(bytes: 9, limit: 8)) {
            try ClipboardFormats.outbound([[ClipboardFormats.text: Data("123456789".utf8)]], limits: limits)
        }
    }

    @Test func imagesTooLargeForTheSessionFallBackToTheirTextExplicitly() throws {
        let big = F.noisePNG(side: 200), limit = 64 << 10
        #expect(big.count > limit)
        let local: ClipboardItem = ["public.png": big, ClipboardFormats.text: Data("caption".utf8)]
        guard case .success(let sent) = ClipboardFormats.encodeOutbound([local], maxMessage: limit) else {
            Issue.record("expected the text fallback"); return
        }
        #expect(sent.omittedImages && sent.message.count <= limit)
        #expect(try ClipboardWire.decode(sent.message) == [.init(flavors: [.init(type: ClipboardFormats.text, data: Array("caption".utf8))])])
        // An image alone has no compatible representation: an explicit limit, nothing sent.
        guard case .failure(.tooLarge) = ClipboardFormats.encodeOutbound([["public.png": big]], maxMessage: limit) else {
            Issue.record("expected an explicit size limit"); return
        }
        guard case .success(let whole) = ClipboardFormats.encodeOutbound([local], maxMessage: HPSSSession.accessoryBudget) else {
            Issue.record("expected the image to fit the session budget"); return
        }
        #expect(!whole.omittedImages)
    }

    @Test func echoCoverageToleratesAddedMacRepresentationsOnly() {
        let sent = ClipboardFingerprint([[ClipboardFormats.text: Data("a".utf8)]])
        #expect(sent.isCovered(by: ClipboardFingerprint([[ClipboardFormats.text: Data("a".utf8), ClipboardFormats.html: Data("<a>".utf8)]])))
        #expect(!sent.isCovered(by: ClipboardFingerprint([[ClipboardFormats.text: Data("b".utf8)]])))
        #expect(!sent.isCovered(by: ClipboardFingerprint([[ClipboardFormats.text: Data("a".utf8)], [ClipboardFormats.text: Data("a".utf8)]])))
    }
}
