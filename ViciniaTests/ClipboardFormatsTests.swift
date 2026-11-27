// Vicinia tests — outbound zlib framing at the byte level, image
// formats (JPEG, TIFF, HEIC, GIF, PNG) and multi-frame bounds, and item counts
// kept apart from sizes. Fixtures are synthetic and deterministic. These tests
// do not establish what the Mac accepts.
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Vicinia

extension ClipboardFixture {
    /// `frames` solid frames of `width`×`height`, encoded by ImageIO as `type`.
    static func image(_ type: UTType, width: Int = 8, height: Int = 6, frames: Int = 1) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        var pixels = [UInt8](repeating: 0x5A, count: width * height * 4)
        let frame = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, frame, nil) }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// 16×12 HEIC made on macOS 27.2.1 with `sips -s format heic` from a synthetic gradient PNG
    /// (an embedded fixture: HEIC encoding is not assumed in the simulator).
    static let heic = Data(base64Encoded: """
        AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABhm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAOZpcHJwAAAAxWlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAEAAAAAwAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcWh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAI0IBAQNwAAADALAAAAMAAAMAHqAQIEHBzDeIeSRZVNwICBgCogABAAlEAcBhckIQFMkAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAboAAABpAAAAAW1kYXQAAAAAAAAAeQAAAGUoAa/gGmHnf/AIv1R3P+D+4Lf0i5FIOJCY2P7I+P8D/o/5qC2e4VgdCmVWxVZ2bL0eZmXlfz+1yfXpOcn0Ou73qPmoIsLH3/ax9YLmtgMIeXSkLK5RuKk//txTnKcq/+YxKjhJwA==
        """, options: .ignoreUnknownCharacters)!

    static func bytes(hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}

@Suite("Clipboard framing, images and item counts")
struct ClipboardFormatsTests {
    typealias F = ClipboardFixture

    // MARK: outbound zlib framing

    @Test func outboundZlibMatchesSyncFlushedBytes() throws {
        let text = Array("hello".utf8)
        let message = try ClipboardWire.encode([.init(flavors: [.init(type: ClipboardFormats.text, data: text)])],
                                               maxMessage: HPSSSession.accessoryBudget)
        let archive = F.archive([[F.Flavor(type: ClipboardFormats.text, tags: [], data: text)]])
        let payload = Array(message.dropFirst(ClipboardWire.headerLength))
        // Default zlib compression with a 15-bit window and Z_SYNC_FLUSH.
        let reference = F.bytes(hex: "789c62606060646060102b284dcac94cd62b2d49b3d02dc849ccccd32d49ad28614000d68cd49c9c7c00000000ffff")
        #expect(payload == reference)
        #expect(Array(payload.prefix(2)) == [0x78, 0x9C] && Array(payload.suffix(4)) == [0x00, 0x00, 0xFF, 0xFF])
        let header = try ClipboardWire.Header(message)
        #expect(header.uncompressed == archive.count && header.compressed == payload.count)
        #expect(try ClipboardWire.inflate(payload, exactly: archive.count) == archive)
        // Not a complete stream: no final block and no Adler-32, so a Z_FINISH inflater never reaches its end.
        #expect(throws: (any Error).self) { try zlibDecompress(payload, limit: archive.count + 64) }
    }

    @Test func largeOutboundArchivesEndInOneSyncFlushAndInflateExactly() throws {
        var seed: UInt32 = 7
        let text = (0..<(300 << 10)).map { _ -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(ascii: "a") + UInt8(seed >> 27)                 // 32 letters: compressible, not trivial
        }
        let items = [ClipboardWire.Item(flavors: [.init(type: ClipboardFormats.text, data: text)])]
        let message = try ClipboardWire.encode(items, maxMessage: HPSSSession.accessoryBudget)
        let payload = Array(message.dropFirst(ClipboardWire.headerLength))
        #expect(Array(payload.suffix(4)) == [0x00, 0x00, 0xFF, 0xFF])
        #expect(try ClipboardWire.decode(message) == items)
    }

    // MARK: image formats and bounds

    @Test(arguments: [UTType.jpeg, .tiff, .gif, .png])
    func encodedImageFormatsKeepTheirBytesAndPassTheHeaderCheck(_ type: UTType) throws {
        let data = F.image(type)
        #expect(ClipboardFormats.validImage(data, type: type.identifier, limits: .standard))
        let wire = try ClipboardFormats.outbound([[type.identifier: data]])
        #expect(wire == [.init(flavors: [.init(type: type.identifier, data: [UInt8](data))])])
    }

    @Test func heicKeepsItsBytesAndIsCheckedFromItsHeader() throws {
        #expect(ClipboardFormats.validImage(F.heic, type: UTType.heic.identifier, limits: .standard))
        #expect(!ClipboardFormats.validImage(F.heic, type: UTType.jpeg.identifier, limits: .standard))  // mislabeled
        var tight = ClipboardLimits.standard
        tight.imagePixels = 16 * 12 - 1
        #expect(!ClipboardFormats.validImage(F.heic, type: UTType.heic.identifier, limits: tight))
        let wire = try ClipboardFormats.outbound([[UTType.heic.identifier: F.heic]])
        #expect(wire == [.init(flavors: [.init(type: UTType.heic.identifier, data: [UInt8](F.heic))])])
    }

    @Test(arguments: [UTType.gif, .tiff])
    func framesAreBoundedInNumberAndInTotalPixels(_ type: UTType) {
        var limits = ClipboardLimits.standard
        limits.imagePixels = 10_000
        limits.imageFrames = 4
        // 60×60 = 3 600 px a frame: each frame fits, two frames fit, three exceed the total.
        #expect(ClipboardFormats.validImage(F.image(type, width: 60, height: 60, frames: 2), type: type.identifier, limits: limits))
        #expect(!ClipboardFormats.validImage(F.image(type, width: 60, height: 60, frames: 3), type: type.identifier, limits: limits))
        #expect(!ClipboardFormats.validImage(F.image(type, width: 10, height: 10, frames: 5), type: type.identifier, limits: limits))
        // The same rules on a file, before its bytes are read.
        let url = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try? F.image(type, width: 60, height: 60, frames: 3).write(to: url)
        #expect(!ClipboardFormats.validImage(at: url, type: type.identifier, limits: limits))
        try? F.image(type, width: 60, height: 60, frames: 2).write(to: url)
        #expect(ClipboardFormats.validImage(at: url, type: type.identifier, limits: limits))
    }

    @Test func aMultiFrameImageOverTheTotalIsDroppedFromAnInboundItemAndTheTextKept() throws {
        var limits = ClipboardLimits.standard
        limits.imagePixels = 10_000
        let gif = F.image(.gif, width: 60, height: 60, frames: 3)
        let local = try ClipboardFormats.inbound([.init(flavors: [.init(type: UTType.gif.identifier, data: [UInt8](gif)),
                                                                  .init(type: ClipboardFormats.text, data: Array("kept".utf8))])],
                                                 limits: limits)
        #expect(local == [[ClipboardFormats.text: Data("kept".utf8)]])
    }

    // MARK: item counts are not sizes

    @Test func itemCountsAreAnExplicitLimitInBothDirections() {
        let limits = ClipboardLimits.standard
        let one = [F.Flavor(type: ClipboardFormats.text, tags: [], data: Array("x".utf8))]
        let archive = F.archive(Array(repeating: one, count: limits.items + 1))
        #expect(throws: ClipboardIssue.tooManyItems(limit: limits.items)) { try ClipboardWire.parseArchive(archive) }
        guard case .failure(.tooManyItems(limits.items)) = ClipboardFormats.decodeInbound(F.message(archive: archive)) else {
            Issue.record("an inbound item count must be reported as a count"); return
        }
        let local = Array(repeating: [ClipboardFormats.text: Data("x".utf8)], count: limits.items + 1)
        #expect(throws: ClipboardIssue.tooManyItems(limit: limits.items)) { try ClipboardFormats.outbound(local) }
        #expect(throws: Never.self) { try ClipboardFormats.outbound(Array(local.dropLast())) }
    }
}
