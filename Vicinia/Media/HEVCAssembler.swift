// Vicinia — Apple HPSS HEVC RTP depacketization and access-unit assembly.
// SPDX-License-Identifier: MIT
//
// Assembly handles the Apple deviations from RFC 7798: a DONL after the NAL
// header of single NALs and APs, no DOND in APs, a DONL in every FU fragment,
// with (SSRC, RTP timestamp) grouping, wrap-aware ordering and incomplete-AU
// rejection. AU-level CMSampleBuffer input, reorder wait only on a sequence
// gap, bounded groups/bytes, typed outputs.

import Foundation

struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data

    /// Parses a plaintext RTP packet (RFC 3550): CSRCs, extension and padding.
    init(_ d: Data) throws {
        let b = d.startIndex
        guard d.count >= 12 else { throw BitstreamError.truncated }
        guard d[b] >> 6 == 2 else { throw BitstreamError.invalid("RTP version") }
        let csrc = Int(d[b] & 0x0F)
        var header = 12 + 4 * csrc
        if d[b] & 0x10 != 0 {
            guard d.count >= header + 4 else { throw BitstreamError.truncated }
            let words = Int(d[b + header + 2]) << 8 | Int(d[b + header + 3])
            header += 4 + 4 * words
        }
        var end = d.count
        if d[b] & 0x20 != 0 {
            let pad = Int(d[b + d.count - 1])
            guard pad > 0, pad <= d.count - header else { throw BitstreamError.invalid("RTP padding") }
            end -= pad
        }
        guard header <= end else { throw BitstreamError.truncated }
        marker = d[b + 1] & 0x80 != 0
        payloadType = d[b + 1] & 0x7F
        sequence = UInt16(d[b + 2]) << 8 | UInt16(d[b + 3])
        timestamp = d[b + 4 ..< b + 8].reduce(0) { $0 << 8 | UInt32($1) }
        ssrc = d[b + 8 ..< b + 12].reduce(0) { $0 << 8 | UInt32($1) }
        payload = d.subdata(in: b + header ..< b + end)
    }
}

/// One HEVC picture of one stripe: every NAL unit of one (SSRC, timestamp)
/// group, in RTP order, DONL removed, without start codes.
struct AccessUnit: Sendable {
    let stripe: Int
    let ssrc: UInt32
    let rtpTimestamp: UInt32
    let firstSequence: UInt16
    let lastSequence: UInt16
    let donl: UInt16?
    let nalUnits: [Data]
    let completedNanos: UInt64
    /// Arrival of the first packet of this picture (start of arrival → presentation).
    var firstArrivalNanos: UInt64 = 0

    var containsIRAP: Bool { nalUnits.contains { HEVCNAL.isIRAP(HEVCNAL.type($0[$0.startIndex])) } }
    var byteCount: Int { nalUnits.reduce(0) { $0 + $1.count } }
}

enum AssemblerOutput {
    case accessUnit(AccessUnit)
    /// A compressed AU was irreversibly lost or malformed; the decoder must
    /// realign at the next random-access point (requested with a FIR).
    case lost(ssrc: UInt32, rtpTimestamp: UInt32, reason: String)
}

/// Not thread-safe: owned by the single serial media context.
final class HEVCAssembler {
    struct Limits {
        var maxPacketsPerAU = 4096
        var maxBytesPerAU = 8 << 20
        var maxPendingAUs = 64
        var gapWaitNanos: UInt64 = 20_000_000      // reorder wait only on a gap
        /// A group whose marker never arrives is a permanent hole (fork
        /// session.py `_PENDING_GROUP_TTL_S` = 0.2 s, "RTP marker timeout").
        var markerTimeoutNanos: UInt64 = 200_000_000
    }

    private struct Key: Hashable { let ssrc: UInt32; let timestamp: UInt32 }
    private struct Group {
        var packets: [(seq: UInt16, marker: Bool, payload: Data)] = []
        var bytes = 0
        var firstArrival: UInt64
        var markerArrival: UInt64?
    }

    let limits: Limits
    let payloadType: UInt8
    private let stripeForSSRC: @Sendable (UInt32) -> Int?
    private var groups: [Key: Group] = [:]
    private var order: [Key] = []
    private var lastMarker: [UInt32: UInt16] = [:]
    private var flushed: Set<Key> = []
    private var flushedOrder: [Key] = []
    private(set) var counters = Counters()

    struct Counters: Sendable {
        var packets = 0, foreignPayloadType = 0, unknownSSRC = 0, malformed = 0
        var duplicates = 0, accessUnits = 0, lost = 0, late = 0
    }

    init(payloadType: UInt8 = 100, limits: Limits = Limits(),
         stripeForSSRC: @escaping @Sendable (UInt32) -> Int?) {
        self.payloadType = payloadType
        self.limits = limits
        self.stripeForSSRC = stripeForSSRC
    }

    func ingest(_ packetBytes: Data, arrivalNanos now: UInt64) -> [AssemblerOutput] {
        counters.packets += 1
        guard let p = try? RTPPacket(packetBytes) else { counters.malformed += 1; return [] }
        guard p.payloadType == payloadType else { counters.foreignPayloadType += 1; return [] }
        guard stripeForSSRC(p.ssrc) != nil else { counters.unknownSSRC += 1; return [] }
        let key = Key(ssrc: p.ssrc, timestamp: p.timestamp)
        if flushed.contains(key) { counters.late += 1; return [] }
        var out: [AssemblerOutput] = []
        if groups[key] == nil {
            if groups.count >= limits.maxPendingAUs, let oldest = order.first {
                out.append(drop(oldest, reason: "pending AU limit"))
            }
            groups[key] = Group(firstArrival: now)
            order.append(key)
        }
        var g = groups[key]!
        if g.packets.contains(where: { $0.seq == p.sequence }) {
            counters.duplicates += 1
        } else {
            g.packets.append((p.sequence, p.marker, p.payload))
            g.bytes += p.payload.count
            if p.marker, g.markerArrival == nil { g.markerArrival = now }
        }
        groups[key] = g
        if g.packets.count > limits.maxPacketsPerAU || g.bytes > limits.maxBytesPerAU {
            out.append(drop(key, reason: "AU exceeds bounds"))
            return out
        }
        out += flushReady(now: now)
        return out
    }

    /// Drives the gap and marker timeouts when no packets arrive (live use).
    func poll(now: UInt64) -> [AssemblerOutput] { flushReady(now: now) }

    /// True while some stripe picture with this RTP timestamp is still being received.
    func isAssembling(timestamp: UInt32) -> Bool { order.contains { $0.timestamp == timestamp } }

    func reset() {
        groups.removeAll(); order.removeAll(); lastMarker.removeAll()
        flushed.removeAll(); flushedOrder.removeAll()
    }

    // MARK: -

    private func flushReady(now: UInt64) -> [AssemblerOutput] {
        var out: [AssemblerOutput] = []
        var i = 0
        while i < order.count {
            let key = order[i]
            guard let g = groups[key] else { order.remove(at: i); continue }
            let sorted = Self.sortedBySequence(g.packets)
            let gapFree = zip(sorted, sorted.dropFirst()).allSatisfy { $1.seq &- $0.seq == 1 }
            let anchored = lastMarker[key.ssrc].map { sorted.first!.seq == $0 &+ 1 } ?? true
            let markerLast = sorted.last?.marker == true
            // The first packet must begin a NAL (not an FU continuation);
            // otherwise the AU's start is still missing (e.g. reordered).
            let first = sorted.first!.payload
            let startsNAL = first.count >= 3 && (HEVCNAL.type(first[first.startIndex]) != HEVCNAL.fragmentation
                || first[first.startIndex + 2] & 0x80 != 0)
            if g.markerArrival != nil, gapFree, markerLast, anchored, startsNAL {
                out.append(complete(key, sorted, firstArrival: g.firstArrival, now: now))
                i = 0                       // a completed AU may unblock earlier logic
                continue
            }
            let waitingSince = g.markerArrival ?? g.firstArrival
            let newerCompleted = order.contains { other in
                other.ssrc == key.ssrc && other != key && groups[other]?.markerArrival != nil
                    && Self.timestampNewer(other.timestamp, than: key.timestamp)
            }
            if now &- waitingSince >= limits.gapWaitNanos && (g.markerArrival != nil || newerCompleted) {
                if let m = sorted.last(where: { $0.marker }) { lastMarker[key.ssrc] = m.seq }
                out.append(drop(key, reason: gapFree ? "AU start missing" : "sequence gap"))
                continue
            }
            if g.markerArrival == nil, now &- g.firstArrival >= limits.markerTimeoutNanos {
                lastMarker[key.ssrc] = nil          // hole of unknown extent: next AU self-anchors
                out.append(drop(key, reason: "RTP marker timeout"))
                continue
            }
            i += 1
        }
        return out
    }

    private func complete(_ key: Key, _ sorted: [(seq: UInt16, marker: Bool, payload: Data)],
                          firstArrival: UInt64, now: UInt64) -> AssemblerOutput {
        remove(key)
        lastMarker[key.ssrc] = sorted.last!.seq
        guard let (nals, donl) = Self.reassemble(sorted.map(\.payload)), !nals.isEmpty else {
            counters.lost += 1
            return .lost(ssrc: key.ssrc, rtpTimestamp: key.timestamp, reason: "malformed payload")
        }
        counters.accessUnits += 1
        return .accessUnit(AccessUnit(
            stripe: stripeForSSRC(key.ssrc)!, ssrc: key.ssrc, rtpTimestamp: key.timestamp,
            firstSequence: sorted.first!.seq, lastSequence: sorted.last!.seq, donl: donl,
            nalUnits: nals, completedNanos: now, firstArrivalNanos: firstArrival))
    }

    private func drop(_ key: Key, reason: String) -> AssemblerOutput {
        remove(key)
        counters.lost += 1
        return .lost(ssrc: key.ssrc, rtpTimestamp: key.timestamp, reason: reason)
    }

    private func remove(_ key: Key) {
        groups[key] = nil
        order.removeAll { $0 == key }
        flushed.insert(key)
        flushedOrder.append(key)
        if flushedOrder.count > 1024 { flushed.remove(flushedOrder.removeFirst()) }
    }

    /// Sequence order with 65535→0 wrap: start after the largest circular gap.
    static func sortedBySequence(_ p: [(seq: UInt16, marker: Bool, payload: Data)])
        -> [(seq: UInt16, marker: Bool, payload: Data)] {
        let s = p.sorted { $0.seq < $1.seq }
        guard s.count > 1, s.last!.seq &- s.first!.seq > 0x8000 else { return s }
        var best = 0, bestGap: UInt16 = 0
        for i in s.indices {
            let gap = s[(i + 1) % s.count].seq &- s[i].seq
            if gap > bestGap { bestGap = gap; best = i }
        }
        let start = (best + 1) % s.count
        return Array(s[start...] + s[..<start])
    }

    static func timestampNewer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && (a &- b) < 0x8000_0000
    }

    /// Apple HPSS HEVC payloads → NAL units. Returns nil on any malformed or
    /// incomplete structure (no truncated NAL is ever produced).
    static func reassemble(_ payloads: [Data]) -> ([Data], UInt16?)? {
        var out: [Data] = []
        var donl: UInt16?
        var fu: Data?
        for pay in payloads {
            let b = pay.startIndex
            guard pay.count >= 2 else { return nil }
            let type = HEVCNAL.type(pay[b])
            switch type {
            case HEVCNAL.aggregation:           // hdr(2) DONL(2) [size(2) nal]...
                guard fu == nil, pay.count >= 4 else { return nil }
                donl = donl ?? (UInt16(pay[b + 2]) << 8 | UInt16(pay[b + 3]))
                var pos = 4
                while pos < pay.count {
                    guard pos + 2 <= pay.count else { return nil }
                    let size = Int(pay[b + pos]) << 8 | Int(pay[b + pos + 1])
                    pos += 2
                    guard size >= 2, pos + size <= pay.count else { return nil }
                    out.append(pay.subdata(in: b + pos ..< b + pos + size))
                    pos += size
                }
            case HEVCNAL.fragmentation:         // hdr(2) FU(1) DONL(2) data
                guard pay.count > 5 else { return nil }
                let fuHeader = pay[b + 2]
                let start = fuHeader & 0x80 != 0, end = fuHeader & 0x40 != 0
                donl = donl ?? (UInt16(pay[b + 3]) << 8 | UInt16(pay[b + 4]))
                if start {
                    guard fu == nil else { return nil }
                    var nal = Data([(pay[b] & 0x81) | ((fuHeader & 0x3F) << 1), pay[b + 1]])
                    nal.append(pay.subdata(in: b + 5 ..< b + pay.count))
                    fu = nal
                } else {
                    guard fu != nil else { return nil }
                    fu!.append(pay.subdata(in: b + 5 ..< b + pay.count))
                }
                if end {
                    out.append(fu!)
                    fu = nil
                }
            default:                            // single NAL: hdr(2) DONL(2) body
                guard fu == nil, pay.count > 4 else { return nil }
                donl = donl ?? (UInt16(pay[b + 2]) << 8 | UInt16(pay[b + 3]))
                var nal = pay.subdata(in: b ..< b + 2)
                nal.append(pay.subdata(in: b + 4 ..< b + pay.count))
                out.append(nal)
            }
        }
        return fu == nil ? (out, donl) : nil
    }
}

/// Global decode order of the stripe group (one shared decoder and DPB).
///
/// Observed on real HPSS sessions: the DONL is
/// one 16-bit counter across the stripe SSRCs, +1 per picture in (RTP
/// timestamp, stripe) order; stripes absent from a partial update take no
/// number. The fork feeds VideoToolbox in arrival order and only states that
/// order must be `(timestamp, tile)` interleaved (hevc.py/vtdecode.py
/// `feed_burst`); arrival order breaks it whenever one stripe's AU waits for a
/// reordered packet while a later stripe's AU completes. This buffer releases
/// complete AUs strictly by DONL: early AUs are held (bounded), a missing
/// number is awaited at most `gapWaitNanos` and then reported as a gap (loss).
/// Release (re)starts only at an IRAP; AUs before it are dropped, never decoded.
/// Not thread-safe: owned by the serial media context.
struct DecodeOrderBuffer {
    enum Event {
        case decode(AccessUnit)
        case skip(AccessUnit, reason: String)
        case gap(expectedDONL: UInt16)
    }

    var gapWaitNanos: UInt64 = 20_000_000
    var maxHeld = 64
    /// Beyond this distance a DONL is a stream discontinuity, not a reorder.
    static let discontinuity: UInt16 = 1024
    private(set) var next: UInt16?                 // nil: not anchored (start, after a loss)
    private var held: [UInt16: AccessUnit] = [:]
    private var blockedSince: UInt64?

    var heldCount: Int { held.count }
    func holds(timestamp: UInt32) -> Bool { held.values.contains { $0.rtpTimestamp == timestamp } }

    mutating func reset() {
        next = nil
        held = [:]
        blockedSince = nil
    }

    mutating func push(_ au: AccessUnit, now: UInt64) -> [Event] {
        guard let d = au.donl else { return [.decode(au)] }     // a profile without DONL keeps arrival order
        guard held[d] == nil else { return [.skip(au, reason: "duplicate DONL")] }
        guard let n = next else {
            if au.containsIRAP { return anchor(at: au, now: now) }
            held[d] = au
            return trimUnanchored()
        }
        let ahead = d &- n
        if ahead == 0 { return release(au, now: now) }
        if ahead <= Self.discontinuity {                        // earlier pictures still missing: hold
            held[d] = au
            if blockedSince == nil { blockedSince = now }
            return held.count > maxHeld ? declareGap(now: now) : []
        }
        if ahead >= 0 &- Self.discontinuity {                   // its turn has passed (given up as lost)
            return [.skip(au, reason: "late (decode order passed)")]
        }
        return declareGap(now: now) + push(au, now: now)       // far jump: continuity lost
    }

    /// Expires a head-of-line wait for a missing DONL.
    mutating func poll(now: UInt64) -> [Event] {
        guard next != nil, let since = blockedSince, now &- since >= gapWaitNanos else { return [] }
        return declareGap(now: now)
    }

    /// Loss reported elsewhere (assembler, decoder): drop the anchor and restart
    /// at the first held IRAP, if any.
    mutating func realign(now: UInt64) -> [Event] {
        next = nil
        blockedSince = nil
        let sorted = orderedHeld()
        guard let irap = sorted.first(where: { $0.containsIRAP }) else { return [] }
        return anchor(at: irap, now: now)
    }

    // MARK: -

    private mutating func declareGap(now: UInt64) -> [Event] {
        guard let n = next else { return [] }
        return [.gap(expectedDONL: n)] + realign(now: now)
    }

    private mutating func anchor(at au: AccessUnit, now: UInt64) -> [Event] {
        let d = au.donl!
        held[d] = nil
        var out: [Event] = []
        for h in orderedHeld() where Int16(bitPattern: h.donl! &- d) < 0 || h.donl! &- d > Self.discontinuity {
            held[h.donl!] = nil
            out.append(.skip(h, reason: "before random access"))   // or another stream segment
        }
        return out + release(au, now: now)
    }

    private mutating func release(_ au: AccessUnit, now: UInt64) -> [Event] {
        var out: [Event] = [.decode(au)]
        var n = au.donl! &+ 1
        while let h = held.removeValue(forKey: n) {
            out.append(.decode(h))
            n &+= 1
        }
        next = n
        blockedSince = held.isEmpty ? nil : now
        return out
    }

    /// Unanchored: keep at most `maxHeld` AUs waiting for an IRAP.
    private mutating func trimUnanchored() -> [Event] {
        var out: [Event] = []
        for h in orderedHeld().prefix(max(0, held.count - maxHeld)) {
            held[h.donl!] = nil
            out.append(.skip(h, reason: "before random access"))
        }
        return out
    }

    /// Held AUs in circular DONL order (the held span is far below 2^15).
    private func orderedHeld() -> [AccessUnit] {
        guard let pivot = held.keys.first else { return [] }
        return held.values.sorted { Int16(bitPattern: $0.donl! &- pivot) < Int16(bitPattern: $1.donl! &- pivot) }
    }
}
