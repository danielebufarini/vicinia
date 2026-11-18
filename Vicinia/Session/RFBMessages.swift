// Vicinia — RFB 003.889 / Apple HPSS control messages (build and parse).
// SPDX-License-Identifier: MIT
//
// Control-message builders, rectangle grammar and display-layout parsing.
// Vicinia's own viewer identity (the 32-byte capability bitmap is kept),
// bounded parsing that distinguishes "needs more bytes" from "cannot be
// delimited" (explicit error).

import Foundation

enum RFB {
    static let version = Array("RFB 003.889\n".utf8)
    static let securityTypeRSA1SRP: UInt8 = 33

    /// Encodings announced in SetEncodings (fork HP_ENCODINGS_FULL). 1100 and
    /// 1101 have no known rectangle grammar and were never received
    /// from the host; `ServerMessageParser` fails explicitly if one arrives.
    static let hpEncodings: [Int32] = [1010, 1011, 1002, 6, 16, 1104, 1100, -223, 1101, 1105, 1107, 1109, 1110]
    static var openingEncodings: [Int32] { hpEncodings.filter { $0 != 1010 } }

    // MARK: client → server

    struct ViewerIdentity {
        /// Vicinia's own identity values, distinct from Apple Screen Sharing's.
        var viewerApp: UInt32 = 0x5643          // "VC"
        var appVersion: (UInt32, UInt32, UInt32) = (0, 1, 0)
        var osVersion: (UInt32, UInt32, UInt32)
        /// Capability bits (not an identity): heartbeat/clipboard/etc. gates as
        /// the working client sends them (fork apple.py).
        static let capabilityBitmap: [UInt8] = {
            var m = [UInt8](repeating: 0, count: 32)
            m[0] = 0xB0; m[2] = 0x0C; m[3] = 0x03; m[4] = 0x90; m[10] = 0x40
            return m
        }()
    }

    static func viewerInfo(_ id: ViewerIdentity) -> [UInt8] {
        var w = ByteWriter(capacity: 66)
        w.u8(0x21); w.u8(0); w.u16(0x3E); w.u16(1)
        w.u32(id.viewerApp)
        w.u32(id.appVersion.0); w.u32(id.appVersion.1); w.u32(id.appVersion.2)
        w.u32(id.osVersion.0); w.u32(id.osVersion.1); w.u32(id.osVersion.2)
        w.append(ViewerIdentity.capabilityBitmap)
        return w.bytes
    }

    /// 12-byte plaintext 0x12 follow-up after ViewerInfo (fork APPLE_0X12_FOLLOWUP).
    static let setEncryptionStart: [UInt8] = [0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1]
    /// 0x12 command 2 ("PostEncryptionToggle"), plaintext.
    static let setEncryptionToggle: [UInt8] = [0x12, 0, 0, 2, 0, 1, 0, 0]

    static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var w = ByteWriter(capacity: 4 + 4 * encodings.count)
        w.u8(0x02); w.u8(0); w.u16(UInt16(encodings.count))
        for e in encodings { w.i32(e) }
        return w.bytes
    }

    static func framebufferUpdateRequest(incremental: Bool, x: UInt16 = 0, y: UInt16 = 0,
                                         w: UInt16 = 0xFFFF, h: UInt16 = 0xFFFF) -> [UInt8] {
        var b = ByteWriter(capacity: 10)
        b.u8(0x03); b.u8(incremental ? 1 : 0); b.u16(x); b.u16(y); b.u16(w); b.u16(h)
        return b.bytes
    }

    /// Native sender/cursor rearming, followed by a nonincremental request.
    /// Required on EVERY layout, even if geometry is unchanged.
    static func rearmUpdates(width: Int, height: Int) -> [UInt8] {
        var w = ByteWriter()
        w.u8(9); w.u8(0); w.u16(1); w.u32(0xFFFF_FFFF)
        w.u16(0); w.u16(0); w.u16(UInt16(clamping: width)); w.u16(UInt16(clamping: height))
        return w.bytes + framebufferUpdateRequest(incremental: false)
    }

    /// Standard RFB pointer event. Coordinates are final host backing units.
    static func pointer(x: UInt16, y: UInt16, buttons: UInt8) -> [UInt8] {
        var w = ByteWriter(); w.u8(5); w.u8(buttons); w.u16(x); w.u16(y)
        return w.bytes
    }

    /// 0x1d SetDisplayConfiguration with the dynamic descriptor (fork
    /// rfb.py `build_virtual_display`): DYNAMIC flag, type 4 (virtual), value 7
    /// at +0x96, 5-entry mode table scaled to the target, 3840×2160 maximum.
    static func virtualDisplay(logicalWidth: Int, logicalHeight: Int, hidpiScale: Double,
                               refreshHz: Double = 60, name: String = "Vicinia Virtual Display") -> [UInt8] {
        let modeCount = 5
        let diSize = 0x9C + 28 * modeCount
        var di = [UInt8](repeating: 0, count: diSize)
        di.putU16(UInt16(diSize), at: 0)
        let nameBytes = Array(name.utf8.prefix(119))
        di.replaceSubrange(2 ..< 2 + nameBytes.count, with: nameBytes)
        di.putU32(1, at: 0x7A)                                  // DYNAMIC_RESOLUTION
        di.putU32(4, at: 0x7E)                                  // virtual display
        di.putU32(Float(369.4545593261719).bitPattern, at: 0x82) // physical size (mm), as the working client
        di.putU32(Float(207.81817626953125).bitPattern, at: 0x86)
        di.putU32(3840, at: 0x8A); di.putU32(2160, at: 0x8E)    // maximum backing
        di.putU16(0, at: 0x92); di.putU16(0, at: 0x94)
        di.putU32(7, at: 0x96)                                  // interoperable value
        di.putU16(UInt16(modeCount), at: 0x9A)
        let template: [(Int, Int)] = [(1920, 1080), (1440, 900), (1920, 1080), (1440, 810), (1312, 848)]
        let sx = Double(logicalWidth) / 1920, sy = Double(logicalHeight) / 1080
        for i in 0..<modeCount {
            let msw = Int(Double(template[i].0) * sx + 0.5), msh = Int(Double(template[i].1) * sy + 0.5)
            let mw = Int(Double(msw) * hidpiScale + 0.5), mh = Int(Double(msh) * hidpiScale + 0.5)
            let m = 0x9C + 28 * i
            di.putU32(UInt32(mw), at: m); di.putU32(UInt32(mh), at: m + 4)
            di.putU32(UInt32(msw), at: m + 8); di.putU32(UInt32(msh), at: m + 12)
            let r = refreshHz.bitPattern
            di.putU32(UInt32(r >> 32), at: m + 16); di.putU32(UInt32(r & 0xFFFF_FFFF), at: m + 20)
            di.putU32(0, at: m + 24)                            // mode flags (no HDR)
        }
        var w = ByteWriter(capacity: 12 + diSize)
        w.u8(0x1D); w.u8(0); w.u16(UInt16(8 + diSize)); w.u16(1); w.u16(1); w.u32(0)
        w.append(di)
        return w.bytes
    }
}

// MARK: server → client

struct FramebufferRect {
    let x: UInt16, y: UInt16, w: UInt16, h: UInt16
    let encoding: Int32
    let body: [UInt8]
}

enum ServerMessage {
    case framebufferUpdate([FramebufferRect])
    case miscStatus(command: UInt16?, body: [UInt8])
    case bell
    case cutText(length: Int)                 // content discarded, never stored
    case clipboardSend(length: Int)           // 0x1f, content discarded, never stored
}

enum ParseResult {
    case complete(ServerMessage, consumed: Int)
    case needMore
}

/// Parses one server message from the start of `b` (the concatenated record
/// bodies). Messages are delimited by their own grammar only: a message may be
/// continued by the following record(s), and a record boundary is
/// never taken as a message boundary. Known-length messages that are out of
/// scope are delimited and discarded; a message or rectangle encoding whose
/// length cannot be determined is an explicit error (no resynchronisation guess).
enum ServerMessageParser {
    static let maxMessage = 8 << 20

    static func parse(_ b: [UInt8]) throws -> ParseResult {
        guard let type = b.first else { return .needMore }
        switch type {
        case 0x00: return try parseFBU(b)
        case 0x02: return .complete(.bell, consumed: 1)
        case 0x03:                                      // ServerCutText: pad×3, u32 len, text
            guard b.count >= 8 else { return .needMore }
            let n = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
            guard n <= maxMessage else { throw WireError.invalid("cut text length") }
            return b.count >= 8 + n ? .complete(.cutText(length: n), consumed: 8 + n) : .needMore
        case 0x14:                                      // MiscStatus: pad, u16 body_len, body
            guard b.count >= 4 else { return .needMore }
            let n = Int(b[2]) << 8 | Int(b[3])
            guard b.count >= 4 + n else { return .needMore }
            let body = Array(b[4 ..< 4 + n])
            let cmd: UInt16? = n >= 4 ? UInt16(body[2]) << 8 | UInt16(body[3]) : nil
            return .complete(.miscStatus(command: cmd, body: body), consumed: 4 + n)
        case 0x1F:                                      // clipboard send: 16-byte header, u32 compressed at +12
            guard b.count >= 16 else { return .needMore }
            let n = Int(b[12]) << 24 | Int(b[13]) << 16 | Int(b[14]) << 8 | Int(b[15])
            guard n <= maxMessage else { throw WireError.invalid("clipboard length") }
            return b.count >= 16 + n ? .complete(.clipboardSend(length: 16 + n), consumed: 16 + n) : .needMore
        default:
            throw WireError.invalid(String(format: "undelimitable server message type 0x%02x", type))
        }
    }

    private static func parseFBU(_ b: [UInt8]) throws -> ParseResult {
        guard b.count >= 4 else { return .needMore }
        let count = Int(b[2]) << 8 | Int(b[3])
        var r = ByteReader(b, offset: 4)
        var rects: [FramebufferRect] = []
        do {
            for _ in 0..<count {
                let x = try r.u16(), y = try r.u16(), w = try r.u16(), h = try r.u16()
                let enc = try r.i32()
                let body: [UInt8]
                switch enc {
                case 1104:                              // cursor: u32 cache id, u32 size, zlib data
                    let head = try r.take(8)
                    let n = Int(head[4]) << 24 | Int(head[5]) << 16 | Int(head[6]) << 8 | Int(head[7])
                    guard n <= maxMessage else { throw WireError.invalid("cursor length") }
                    body = head + (try r.take(n))
                case 1103:                              // rekey payload, fixed 36 bytes
                    body = try r.take(36)
                case 6, 16:                             // zlib / ZRLE pixels: u32 length + data, discarded
                    let n = Int(try r.u32())
                    guard n <= maxMessage else { throw WireError.invalid("pixel rect length") }
                    try r.skip(n)
                    body = []
                case -223:                              // DesktopSize: no payload
                    body = []
                case 1010, 1011, 1002, 1105, 1107, 1109, 1110:
                    // u16 size + body (1105 = 0x451 layout; 1011/1107/1109/1110 = 0x3f3/0x453/0x455/0x456)
                    let n = Int(try r.u16())
                    body = try r.take(n)
                default:
                    throw WireError.invalid("undelimitable framebuffer encoding \(enc)")
                }
                rects.append(FramebufferRect(x: x, y: y, w: w, h: h, encoding: enc, body: body))
            }
        } catch WireError.truncated {
            guard b.count < maxMessage else { throw WireError.invalid("framebuffer update too large") }
            return .needMore
        }
        return .complete(.framebufferUpdate(rects), consumed: r.offset)
    }
}

/// Media-stream message carried in an encoding-1010 rectangle (fork mediamsg.py).
struct MediaStreamMessage {
    let kind: UInt16                 // 1 ports, 2 answer, 3 error
    let body: [UInt8]
    var ports: (audio: UInt16, video: UInt16, video2: UInt16)? {
        guard kind == 1, body.count >= 24 else { return nil }
        return (UInt16(body[8]) << 8 | UInt16(body[9]), UInt16(body[14]) << 8 | UInt16(body[15]),
                UInt16(body[20]) << 8 | UInt16(body[21]))
    }
    var error: (UInt32, UInt32)? {
        guard kind == 3, body.count >= 16 else { return nil }
        var r = ByteReader(body, offset: 8)
        return ((try? r.u32()) ?? 0, (try? r.u32()) ?? 0)
    }

    init?(_ body: [UInt8]) {
        guard body.count >= 8 else { return nil }
        kind = UInt16(body[0]) << 8 | UInt16(body[1])
        self.body = body
    }

    var summary: String {
        if let p = ports { return "message 1 (ports audio=\(p.audio) video=\(p.video) video2=\(p.video2))" }
        if let e = error { return "message 3 (error type=\(e.0) sub-code=\(e.1))" }
        return "message \(kind) (\(body.count) B)"
    }
}

/// AppleDisplayLayout (0x451) header: scaled and backing size of the canvas.
struct DisplayLayout: Equatable, Sendable {
    let scaledWidth: Int, scaledHeight: Int, backingWidth: Int, backingHeight: Int
    let displays: [DesktopGeometry]

    init?(_ body: [UInt8]) {
        guard body.count >= 20 else { return nil }
        var r = ByteReader(body, offset: 2)
        guard let sw = try? r.u16(), let sh = try? r.u16(), let bw = try? r.u16(), let bh = try? r.u16() else { return nil }
        scaledWidth = Int(sw); scaledHeight = Int(sh); backingWidth = Int(bw); backingHeight = Int(bh)
        let count = Int(body[18]) << 8 | Int(body[19])
        guard count <= 16, body.count >= 20 + count * 56 else { return nil }
        var entries: [DesktopGeometry] = []
        for i in 0..<count {
            var entry = ByteReader(body, offset: 20 + i * 56 + 20)
            func rect(_ r: inout ByteReader) -> CGRect? {
                guard let y0 = try? r.u16(), let x0 = try? r.u16(), let y1 = try? r.u16(), let x1 = try? r.u16(),
                      x1 > x0, y1 > y0 else { return nil }
                return CGRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
            }
            guard let logical = rect(&entry), let backing = rect(&entry) else { return nil }
            entries.append(DesktopGeometry(logical: logical, backing: backing))
        }
        displays = entries
    }

    var geometry: DesktopGeometry? { displays.count == 1 ? displays[0] : nil }
}
