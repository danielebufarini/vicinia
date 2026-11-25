// Vicinia — MediaFeedback packet builders and rate-control state.
// SPDX-License-Identifier: MIT
//
// RTCP feedback: RR with report blocks, empty SR, AVPF FIR + PLI + legacy
// FIR (PT 192) compound, standalone RTCP APP "RCTL" every 50 ms (layout per
// remotex rate-control protocol notes), and the RCTL relative-delay estimator.
// No fields are invented.

import Foundation

enum RTCPBuild {
    static func rr(sender: UInt32, sources: [(ssrc: UInt32, extendedSeq: UInt32, lsr: UInt32, dlsr: UInt32)]) -> [UInt8] {
        var w = ByteWriter()
        let rc = min(sources.count, 31)
        w.u8(0x80 | UInt8(rc)); w.u8(201); w.u16(UInt16(1 + 6 * rc)); w.u32(sender)
        for s in sources.prefix(rc) {
            w.u32(s.ssrc); w.u32(0); w.u32(s.extendedSeq); w.u32(0); w.u32(s.lsr); w.u32(s.dlsr)
        }
        return w.bytes
    }

    static func emptySR(sender: UInt32, now: Date = Date()) -> [UInt8] {
        let t = now.timeIntervalSince1970
        let ntpSec = UInt32(truncatingIfNeeded: Int64(t) + 2_208_988_800)
        let ntpFrac = UInt32(truncatingIfNeeded: Int64((t - floor(t)) * 4_294_967_296))
        var w = ByteWriter()
        w.u8(0x80); w.u8(200); w.u16(6); w.u32(sender); w.u32(ntpSec); w.u32(ntpFrac)
        w.u32(UInt32(truncatingIfNeeded: Int64(t * 90000))); w.u32(0); w.u32(0)
        return w.bytes
    }

    /// Compound recovery request: RR + AVPF FIR (PT 206 FMT 4) + PLI (FMT 1) + legacy FIR (PT 192).
    static func recoveryRequest(sender: UInt32, target: UInt32, firSequence: UInt8) -> [UInt8] {
        var w = ByteWriter()
        w.append(rr(sender: sender, sources: []))
        w.u8(0x80 | 4); w.u8(206); w.u16(4); w.u32(sender); w.u32(0); w.u32(target); w.u8(firSequence); w.zeros(3)
        w.u8(0x80 | 1); w.u8(206); w.u16(2); w.u32(sender); w.u32(target)
        w.u8(0x80); w.u8(192); w.u16(1); w.u32(target)
        return w.bytes
    }

    static func rctl(sender: UInt32, echoTimestamp: UInt32, holdMs: Double, clockSeconds: Double,
                     delaySeconds: Double, received: Int, bandwidthKbps: Int) -> [UInt8] {
        var w = ByteWriter(capacity: 32)
        w.u8(0x80); w.u8(204); w.u16(7); w.u32(sender); w.append(Array("RCTL".utf8))
        w.u8(0x85); w.u8(0); w.u16(4)
        w.u16(UInt16((echoTimestamp >> 8) & 0xFFFF)); w.u32(0)
        w.u16(UInt16(max(0, min(holdMs, 65535))))
        w.u16(UInt16(truncatingIfNeeded: Int64(clockSeconds * 1024)))
        w.u16(UInt16(max(0, min(delaySeconds * 8192, 65535))))
        w.u16(UInt16(received & 0x0FFF))
        w.u16(UInt16(max(0, min(bandwidthKbps, 65535))))
        return w.bytes
    }

    /// (ssrc, middle 32 bits of NTP) for each SR in a compound RTCP packet.
    static func senderReports(_ p: Data) -> [(UInt32, UInt32)] {
        let b = [UInt8](p)
        var out: [(UInt32, UInt32)] = [], pos = 0
        while pos + 4 <= b.count {
            let words = (Int(b[pos + 2]) << 8) | Int(b[pos + 3])
            let length = (words + 1) * 4
            guard length > 0, pos + length <= b.count else { break }
            if b[pos + 1] == 200, length >= 28 {
                var r = ByteReader(b, offset: pos + 4)
                if let ssrc = try? r.u32(), let sec = try? r.u32(), let frac = try? r.u32() {
                    out.append((ssrc, (sec & 0xFFFF) << 16 | (frac >> 16)))
                }
            }
            pos += length
        }
        return out
    }
}

/// RCTL relative one-way delay estimator driven by stripe-0 pictures.
struct RctlState {
    static let videoClockHz = 24_000.0
    private(set) var ssrc: UInt32?
    private(set) var received = 0
    private(set) var lastTimestamp: UInt32?
    private(set) var lastArrival = 0.0
    private(set) var delaySeconds = 0.0
    private var base: (Double, UInt32)?
    private var lastPictureTimestamp: UInt32?
    private var short: Double?, long: Double?

    mutating func onPacket(ssrc: UInt32, stripe: Int, timestamp: UInt32, arrival: Double) {
        if stripe == 0, ssrc != self.ssrc { self = RctlState(); self.ssrc = ssrc }
        received += 1
        lastTimestamp = timestamp
        lastArrival = arrival
        guard stripe == 0, timestamp != lastPictureTimestamp else { return }
        lastPictureTimestamp = timestamp
        if base == nil { base = (arrival, timestamp) }
        let (a0, t0) = base!
        let lag = (arrival - a0) - Double(timestamp &- t0) / Self.videoClockHz
        if let s = short, let l = long, abs(lag - s) <= 30, abs(lag - l) <= 30 {
            short = 0.9 * s + 0.1 * lag
            long = 0.9999 * l + 0.0001 * lag
        } else {
            short = lag; long = lag
        }
        var d = short! - long!
        if d < 0 { long = short; d = 0 }
        delaySeconds = d
    }
}
