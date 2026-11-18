// Vicinia — one session-owned pressed-state ledger, logical coordinates only.
// RFB key/pointer grammar for the HPSS control channel.
// SPDX-License-Identifier: MIT
import Foundation

enum RemoteInput: Sendable {
    case move(CGPoint), buttons(CGPoint, UInt8), scroll(CGPoint, UInt8, Int), key(UInt32, Bool), release, pointerRelease
    var isMove: Bool { if case .move = self { true } else { false } }
    var kindName: String {
        switch self {
        case .move: "move"
        case .buttons: "buttons"
        case .scroll: "scroll"
        case .key: "key"
        case .release: "release"
        case .pointerRelease: "pointerRelease"
        }
    }
}

struct InputState {
    private(set) var epoch: UInt64 = 0
    private(set) var enabled = false
    private(set) var buttons: UInt8 = 0
    private(set) var keys: [UInt32] = []
    private var point = CGPoint.zero
    private var geometry: DesktopGeometry?

    mutating func activate(_ geometry: DesktopGeometry) { self.geometry = geometry; epoch &+= 1; enabled = true }
    // Close the gate immediately; retain dispatched presses and their geometry
    // until the mandatory release reaches the existing serial send boundary.
    mutating func invalidate() { enabled = false; epoch &+= 1 }
    mutating func discard() {
        invalidate()
        buttons = 0; keys.removeAll()
    }
    mutating func release() -> [UInt8] {
        var bytes: [UInt8] = []
        if buttons != 0, let geometry {
            let p = geometry.wirePoint(fromDesktop: point)
            bytes += RFB.pointer(x: p.x, y: p.y, buttons: 0)
        }
        for key in keys.reversed() { bytes += RFB.key(key, down: false) }
        buttons = 0; keys.removeAll()
        return bytes
    }
    /// Pointer-lock handover: release remotely held buttons, keep held keys.
    /// Empty (sent as nothing) when no button is held, like `release()`.
    mutating func releasePointer() -> [UInt8] {
        var bytes: [UInt8] = []
        if buttons != 0, let geometry {
            let p = geometry.wirePoint(fromDesktop: point)
            bytes += RFB.pointer(x: p.x, y: p.y, buttons: 0)
        }
        buttons = 0
        return bytes
    }
    func accepts(epoch: UInt64) -> Bool { enabled && epoch == self.epoch }
    mutating func encode(_ event: RemoteInput, epoch: UInt64) -> [UInt8] {
        guard accepts(epoch: epoch), let geometry else { return [] }
        switch event {
        case .release: return release()
        case .pointerRelease: return releasePointer()
        case .move(let p): point = p
        case .buttons(let p, let mask): point = p; buttons = mask
        case .scroll(let p, let wheel, let count):
            point = p
            let position = geometry.wirePoint(fromDesktop: p)
            let pulse = RFB.pointer(x: position.x, y: position.y, buttons: buttons | wheel)
                + RFB.pointer(x: position.x, y: position.y, buttons: buttons)
            return (0..<min(64, max(0, count))).flatMap { _ in pulse }
        case .key(let key, let down):
            if down { if !keys.contains(key) { keys.append(key) } }
            else { keys.removeAll { $0 == key } }
            return RFB.key(key, down: down)
        }
        let p = geometry.wirePoint(fromDesktop: point)
        return RFB.pointer(x: p.x, y: p.y, buttons: buttons)
    }
}

extension RFB {
    static func key(_ keysym: UInt32, down: Bool) -> [UInt8] {
        var w = ByteWriter(); w.u8(4); w.u8(down ? 1 : 0); w.u16(0); w.u32(keysym)
        return w.bytes
    }
}

// Pinned input.py _build_msg10_pointer: Apple cursor-tracker side effects
// require the encrypted event wrapper, even inside sealed control records.
// Convert the ledger's standard RFB L/M/R mask to Apple's L/R/M once here.
enum AppleInputWire {
    static func wrap(_ bytes: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(bytes), out: [UInt8] = []
        while r.remaining > 0 {
            switch try r.u8() {
            case 5:
                let mask = try r.u8(), x = try r.u16(), y = try r.u16()
                let appleMask = (mask & 0xf9) | ((mask & 2) << 1) | ((mask & 4) >> 1)
                var w = ByteWriter(); w.zeros(10); w.u8(0xff); w.u8(appleMask); w.u16(x); w.u16(y)
                out += [0x10, 0] + (try Crypto.aesECBEncryptBlock(key: key, block: w.bytes))
            case 4: out += [4] + (try r.take(7))
            default: throw WireError.invalid("input event type")
            }
        }
        return out
    }
}

// Queued input remains an event: only the serialized drain may encode it and
// mutate dispatched state. An untagged release is also an empty-send barrier.
enum ControlWrite {
    case message([UInt8])
    case input(RemoteInput, epoch: UInt64)
    case release

    var queuedByteCount: Int {
        switch self {
        case .message(let bytes): bytes.count
        case .input(.scroll(_, _, let count), _): min(64, max(0, count)) * 12
        case .input: 8
        case .release: 0 // no payload allocated until the drain sees current state
        }
    }

    func seal(records: RecordLayer, input: inout InputState) throws -> [UInt8]? {
        let bytes: [UInt8]
        let wrapsInput: Bool
        switch self {
        case .message(let message): bytes = message; wrapsInput = false
        case .input(let event, let epoch): bytes = input.encode(event, epoch: epoch); wrapsInput = true
        case .release: bytes = input.release(); wrapsInput = true
        }
        guard !bytes.isEmpty else { return nil }
        let payload = wrapsInput ? try AppleInputWire.wrap(bytes, key: records.wrapKey) : bytes
        return try records.seal(payload)
    }
}
