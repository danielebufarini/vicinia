// Vicinia — Adaptive media offer (0x1c MediaStreamOptions) and answer parsing.
// SPDX-License-Identifier: MIT
//
// Protobuf MediaBlob, f9 bitrate tier list, audio-off field4 = 1000,
// binary-plist wrapper, 0x1c layout and F5 canvas extraction. HEVC-only
// codec bank (negotiates HEVC 4:4:4), first-video 60 fps + no-cursor flags with
// second-video enablement cleared (0x05), Vicinia client name and the
// device's own model/build in RemoteEndpointInfo.

import Foundation
import zlib

struct MediaKeys {
    /// 46-byte SRTP master key||salt blobs, client→host ("v") and host→client ("s").
    let audioToHost: [UInt8], audioFromHost: [UInt8], videoToHost: [UInt8], videoFromHost: [UInt8]

    static func random() throws -> MediaKeys {
        MediaKeys(audioToHost: try Crypto.randomBytes(46), audioFromHost: try Crypto.randomBytes(46),
                  videoToHost: try Crypto.randomBytes(46), videoFromHost: try Crypto.randomBytes(46))
    }
}

struct MediaOffer {
    let message: [UInt8]          // complete 0x1c message (to be record-encrypted)
    let keys: MediaKeys
    let videoSSRC: UInt32         // our viewer SSRC on the video leg
    let audioSSRC: UInt32
    static let tilesPerFrame = 4
    /// Big-endian: bit0 60 fps stream 1, bit2 do not send cursor; bit1 (stream 2) clear.
    static let configFlags: UInt32 = 0x05

    static func make(clientName: String, hardwareModel: String, osBuild: String) throws -> MediaOffer {
        let keys = try MediaKeys.random()
        let rnd = try Crypto.randomBytes(8)
        let videoSSRC = rnd[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let audioSSRC = rnd[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let endpoint = remoteEndpointInfo(hardwareModel: hardwareModel, osBuild: osBuild)
        let video = try plist(mode: 7, blob: mediaBlob(video: true, sessionID: videoSSRC, clientName: clientName),
                              endpoint: endpoint)
        let audio = try plist(mode: 8, blob: mediaBlob(video: false, sessionID: audioSSRC, clientName: clientName),
                              endpoint: endpoint)
        return MediaOffer(message: try build0x1c(audio: audio, video: video, keys: keys),
                          keys: keys, videoSSRC: videoSSRC, audioSSRC: audioSSRC)
    }

    // MARK: protobuf

    private static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out = [UInt8]()
        while v > 0x7F { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }
    private static func fieldVarint(_ n: UInt64, _ v: UInt64) -> [UInt8] { varint(n << 3) + varint(v) }
    private static func fieldBytes(_ n: UInt64, _ v: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(UInt64(v.count)) + v }

    /// f9 tier list (kind, bps, buffer) — preserved bitrate entries incl. HP tiers.
    private static let tiers: [(UInt64, UInt64, UInt64?)] = [
        (0, 40_000_000, 12288), (0, 6_000_000, 131072), (4074, 0, 16384), (16, 4100, nil),
        (0, 75_000_000, 524288), (0, 20_000_000, 98304), (4, 6500, nil), (0, 60_000_000, 262144),
        (1, 299, nil), (0, 100_000_000, 1_048_576),
    ]

    static func mediaBlob(video: Bool, sessionID: UInt32, clientName: String,
                          timestampNanos: UInt64 = UInt64(Date().timeIntervalSince1970 * 1e9)) -> [UInt8] {
        let desc: [UInt8]
        if video {
            let res = fieldVarint(1, 1) + fieldVarint(2, 1) + fieldVarint(3, 50115) + fieldVarint(4, 0)
            let resAlt = fieldVarint(1, 1) + fieldVarint(2, 2) + fieldVarint(3, 50115) + fieldVarint(4, 0)
            // Codec constant 100 with this parameter string negotiates HEVC 4:4:4 with the host.
            let params = Array("FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;".utf8)
            let bank = fieldVarint(1, 100) + fieldBytes(2, res) + fieldBytes(2, resAlt)
                + fieldBytes(3, params) + fieldVarint(4, 14)
            let d = fieldVarint(1, UInt64(sessionID)) + fieldVarint(2, 1) + fieldBytes(3, bank)
                + fieldVarint(6, UInt64(tilesPerFrame)) + fieldVarint(7, 1) + fieldVarint(8, 63)
                + fieldVarint(9, 1) + fieldVarint(12, 1)
            desc = fieldBytes(5, d)
        } else {
            let d = fieldVarint(1, UInt64(sessionID)) + fieldVarint(2, 0) + fieldVarint(3, 0)
                + fieldVarint(4, 1000) + fieldVarint(5, 0) + fieldVarint(6, 0)   // 1000: PT-101 bit clear = no audio
            desc = fieldBytes(3, d)
        }
        var f9 = [UInt8]()
        for (kind, bps, buf) in tiers {
            var body: [UInt8] = [0x08] + varint(kind) + [0x10] + varint(bps)
            if let buf { body += [0x18] + varint(buf) }
            f9 += [0x4A] + varint(UInt64(body.count)) + body
        }
        return fieldVarint(1, 1) + fieldVarint(2, 1) + desc + fieldBytes(6, Array(clientName.utf8))
            + fieldVarint(8, 0) + f9 + fieldVarint(13, timestampNanos)
            + fieldVarint(14, 2) + fieldVarint(16, 0) + fieldVarint(18, 1)
    }

    static func remoteEndpointInfo(hardwareModel: String, osBuild: String) -> [UInt8] {
        func str(_ tag: UInt8, _ s: String) -> [UInt8] { let b = Array(s.utf8.prefix(127)); return [tag, UInt8(b.count)] + b }
        return [0x08, 0x00, 0x10, 0x01] + str(0x1A, hardwareModel) + str(0x22, "1.0.0") + str(0x2A, osBuild)
    }

    private static func plist(mode: Int, blob: [UInt8], endpoint: [UInt8]) throws -> [UInt8] {
        let dict: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": Data(endpoint),
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": Data(try zlibCompress(blob)),
            "avcMediaStreamOptionCallID": UUID().uuidString.uppercased(),
        ]
        return [UInt8](try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0))
    }

    static func build0x1c(audio: [UInt8], video: [UInt8], keys: MediaKeys) throws -> [UInt8] {
        let total = audio.count + video.count + 0xD8
        guard total + 4 <= 0xFFFF else { throw WireError.invalid("offer size") }
        var b = [UInt8](repeating: 0, count: total + 4)
        b[0] = 0x1C
        b.putU16(UInt16(total), at: 2)
        b.putU16(3, at: 4)
        b.putU32(configFlags, at: 6)
        b.putU16(UInt16(audio.count), at: 10)
        b.putU16(UInt16(video.count), at: 12)
        b.replaceSubrange(0x14 ..< 0x24, with: try Crypto.randomBytes(16))      // CallID UUID bytes
        b.replaceSubrange(0x24 ..< 0x52, with: keys.audioToHost)
        b.replaceSubrange(0x52 ..< 0x80, with: keys.audioFromHost)
        b.replaceSubrange(0x80 ..< 0x80 + audio.count, with: audio)
        let vo = 0x80 + audio.count
        b.replaceSubrange(vo ..< vo + 0x2E, with: keys.videoToHost)
        b.replaceSubrange(vo + 0x2E ..< vo + 0x5C, with: keys.videoFromHost)
        b.replaceSubrange(vo + 0x5C ..< vo + 0x5C + video.count, with: video)
        return b
    }

    // MARK: answer

    /// (canvas width, height, tiles) from an answer FBU's embedded bplist F5,
    /// or nil when the answer carries no canvas.
    static func canvas(inAnswer body: [UInt8]) -> (Int, Int, Int)? {
        let marker = Array("bplist".utf8)
        var idx = 0
        while let start = firstIndex(of: marker, in: body, from: idx) {
            idx = start + 6
            var dict: [String: Any]?
            var end = start + 40
            while end <= body.count, dict == nil {
                dict = try? PropertyListSerialization.propertyList(from: Data(body[start..<end]), format: nil) as? [String: Any]
                end += 1
            }
            guard let blob = dict?["avcMediaStreamNegotiatorMediaBlob"] as? Data,
                  let dec = try? zlibDecompress([UInt8](blob), limit: 1 << 20) else { continue }
            if let c = canvasFields(dec) { return c }
        }
        return nil
    }

    private static func canvasFields(_ pb: [UInt8]) -> (Int, Int, Int)? {
        var it = ProtoIterator(pb)
        while let (field, wire, value, bytes) = it.next() {
            guard field == 5, wire == 2, let bytes else { _ = value; continue }
            var sub = ProtoIterator(bytes)
            var w = 0, h = 0, t = 0
            while let (sf, sw, sv, _) = sub.next() {
                guard sw == 0 else { continue }
                if sf == 4 { w = Int(sv) } else if sf == 5 { h = Int(sv) } else if sf == 6 { t = Int(sv) }
            }
            if w > 0, h > 0 { return (w, h, t) }
        }
        return nil
    }

    /// Byte ranges of the audio, video and second-video negotiator blobs of an
    /// answer (media-stream message 2): their big-endian lengths are at offsets
    /// 8, 10 and 12 of the message, the blobs follow from offset 18 in that order.
    static func answerBlobs(_ body: [UInt8]) -> (audio: Range<Int>, video: Range<Int>, video2: Range<Int>)? {
        guard body.count >= 18, body[0] == 0, body[1] == 2 else { return nil }
        let a = Int(body[8]) << 8 | Int(body[9]), v = Int(body[10]) << 8 | Int(body[11])
        let v2 = Int(body[12]) << 8 | Int(body[13])
        guard 18 + a + v + v2 <= body.count else { return nil }
        return (18 ..< 18 + a, 18 + a ..< 18 + a + v, 18 + a + v ..< 18 + a + v + v2)
    }

    /// LTRP flag of the video answer only (field 7 of the first field-5 stream
    /// description of the video blob); the audio and second-video blobs are never read.
    static func videoLTRP(inAnswer body: [UInt8]) -> LTRPNegotiation {
        guard let blobs = answerBlobs(body) else { return .unparseable("answer layout") }
        let blob = Array(body[blobs.video])
        guard !blob.isEmpty else { return .absent("empty video answer") }
        let compressed: [UInt8]
        if blob.starts(with: Array("bplist".utf8)) {
            guard let dict = try? PropertyListSerialization.propertyList(from: Data(blob), format: nil) as? [String: Any],
                  let data = dict["avcMediaStreamNegotiatorMediaBlob"] as? Data else {
                return .unparseable("video property list")
            }
            compressed = [UInt8](data)
        } else {
            compressed = blob                       // bare negotiator blob (offer without endpoint information)
        }
        guard let pb = try? zlibDecompress(compressed, limit: 1 << 20) else { return .unparseable("video negotiator blob") }
        var it = ProtoIterator(pb), stream: [UInt8]?
        while let (field, wire, _, bytes) = it.next() {
            if field == 5, wire == 2, stream == nil { stream = bytes }
        }
        guard it.isAtEnd else { return .unparseable("video negotiator protobuf") }
        guard let stream else { return .absent("no video stream description") }
        var sub = ProtoIterator(stream), ltrp: UInt64?
        while let (field, wire, value, _) = sub.next() {
            if field == 7, wire == 0, ltrp == nil { ltrp = value }
        }
        guard sub.isAtEnd else { return .unparseable("video stream description") }
        guard let ltrp else { return .absent("no field 5.7") }
        return ltrp != 0 ? .enabled : .disabled
    }

    private static func firstIndex(of needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i ..< i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}

/// Minimal bounded protobuf field iterator (varint / length-delimited / fixed).
struct ProtoIterator {
    private let b: [UInt8]
    private var i = 0
    init(_ b: [UInt8]) { self.b = b }
    /// After `next()` returned nil: true when every byte was consumed (not malformed).
    var isAtEnd: Bool { i >= b.count }

    private mutating func varint() -> UInt64? {
        var v: UInt64 = 0, shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]; i += 1
            v |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return v }
            shift += 7
        }
        return nil
    }

    /// A field that cannot be read leaves the position at its start (so `isAtEnd` is false).
    mutating func next() -> (UInt64, UInt64, UInt64, [UInt8]?)? {
        let start = i
        guard let field = nextField() else { i = start; return nil }
        return field
    }

    private mutating func nextField() -> (UInt64, UInt64, UInt64, [UInt8]?)? {
        guard i < b.count, let tag = varint() else { return nil }
        let field = tag >> 3, wire = tag & 7
        switch wire {
        case 0: guard let v = varint() else { return nil }; return (field, 0, v, nil)
        case 2:
            guard let n = varint(), n <= UInt64(b.count - i) else { return nil }
            defer { i += Int(n) }
            return (field, 2, n, Array(b[i ..< i + Int(n)]))
        case 1: guard b.count - i >= 8 else { return nil }; i += 8; return (field, 1, 0, nil)
        case 5: guard b.count - i >= 4 else { return nil }; i += 4; return (field, 5, 0, nil)
        default: return nil
        }
    }
}

func zlibCompress(_ input: [UInt8]) throws -> [UInt8] {
    var outLen = compressBound(uLong(input.count))
    var out = [UInt8](repeating: 0, count: Int(outLen))
    let st = compress(&out, &outLen, input, uLong(input.count))
    guard st == Z_OK else { throw WireError.invalid("zlib compress \(st)") }
    return Array(out.prefix(Int(outLen)))
}

/// Inflates a zlib stream, bounded by `limit` output bytes.
func zlibDecompress(_ input: [UInt8], limit: Int) throws -> [UInt8] {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw WireError.invalid("inflateInit")
    }
    defer { inflateEnd(&stream) }
    var out = [UInt8](repeating: 0, count: limit)
    var input = input
    let st: Int32 = input.withUnsafeMutableBufferPointer { inp in
        out.withUnsafeMutableBufferPointer { o in
            stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
            stream.next_out = o.baseAddress; stream.avail_out = uInt(o.count)
            return inflate(&stream, Z_FINISH)
        }
    }
    guard st == Z_STREAM_END else { throw WireError.invalid("inflate \(st)") }
    return Array(out.prefix(Int(stream.total_out)))
}
