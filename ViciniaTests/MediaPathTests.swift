// Vicinia tests — HEVC RTP assembly, control parsing and the media offer.
// SPDX-License-Identifier: MIT

import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import Vicinia

@Suite("HEVC assembler")
struct AssemblerTests {
    private func packet(seq: UInt16, ts: UInt32 = 90_000, ssrc: UInt32 = 0x10, marker: Bool, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(ts); w.u32(ssrc); w.append(payload)
        return Data(w.bytes)
    }
    private let slice: [UInt8] = [0x02, 0x01] + (0..<40).map { UInt8($0) }       // TRAIL_R NAL

    /// FU start/end with a DONL in every fragment (Apple variant).
    private func fragments(_ nal: [UInt8]) -> ([UInt8], [UInt8]) {
        let fuHeader = HEVCNAL.type(nal[0])
        let first: [UInt8] = [0x62, 0x01, 0x80 | fuHeader, 0x00, 0x07] + nal[2..<20]
        let last: [UInt8] = [0x62, 0x01, 0x40 | fuHeader, 0x00, 0x07] + nal[20...]
        return (first, last)
    }

    private func assembler() -> HEVCAssembler { HEVCAssembler(stripeForSSRC: { $0 == 0x10 ? 0 : nil }) }

    @Test func reassemblesFragmentsInAnyOrder() throws {
        let a = assembler()
        let (f1, f2) = fragments(slice)
        #expect(a.ingest(packet(seq: 2, marker: true, payload: f2), arrivalNanos: 1).isEmpty)
        let out = a.ingest(packet(seq: 1, marker: false, payload: f1), arrivalNanos: 2)
        guard case .accessUnit(let au)? = out.first else { Issue.record("no AU"); return }
        #expect(au.nalUnits.map { [UInt8]($0) } == [slice] && au.donl == 7)
    }

    @Test func aggregationPacketAndWrap() {
        let a = assembler()
        let vps: [UInt8] = [0x40, 0x01, 1, 2, 3], sps: [UInt8] = [0x42, 0x01, 4, 5]
        var ap: [UInt8] = [0x60, 0x01, 0x00, 0x01]
        for n in [vps, sps] { ap += [0, UInt8(n.count)] + n }
        let (f1, f2) = fragments(slice)
        _ = a.ingest(packet(seq: 65_535, marker: false, payload: ap), arrivalNanos: 1)
        _ = a.ingest(packet(seq: 0, marker: false, payload: f1), arrivalNanos: 2)
        let out = a.ingest(packet(seq: 1, marker: true, payload: f2), arrivalNanos: 3)
        guard case .accessUnit(let au)? = out.first else { Issue.record("no AU"); return }
        #expect(au.nalUnits.map { [UInt8]($0) } == [vps, sps, slice])
    }

    @Test func duplicatesAreIgnored() {
        let a = assembler()
        let (f1, f2) = fragments(slice)
        _ = a.ingest(packet(seq: 1, marker: false, payload: f1), arrivalNanos: 1)
        _ = a.ingest(packet(seq: 1, marker: false, payload: f1), arrivalNanos: 2)
        let out = a.ingest(packet(seq: 2, marker: true, payload: f2), arrivalNanos: 3)
        #expect(out.count == 1)
        #expect(a.counters.duplicates == 1)
    }

    @Test func gapIsReportedAsLossAfterWait() {
        let a = assembler()
        let (f1, f2) = fragments(slice)
        _ = a.ingest(packet(seq: 1, marker: false, payload: f1), arrivalNanos: 0)
        _ = a.ingest(packet(seq: 3, marker: true, payload: f2), arrivalNanos: 1_000_000)
        #expect(a.poll(now: 10_000_000).isEmpty)                 // within the 20 ms gap wait
        guard case .lost(_, _, let reason)? = a.poll(now: 30_000_000).first else { Issue.record("no loss"); return }
        #expect(reason == "sequence gap")
    }

    /// A group whose marker never arrives expires after the 200 ms marker timeout; the next AU
    /// on that SSRC is not dropped for the unknown extent of the hole.
    @Test func markerlessGroupExpiresAndNextAUSelfAnchors() {
        let a = assembler()
        let (f1, _) = fragments(slice)
        let anchor = a.ingest(packet(seq: 5, ts: 0, marker: true, payload: [0x02, 0x01, 0x00, 0x07] + slice[2...]),
                              arrivalNanos: 0)
        guard case .accessUnit? = anchor.first else { Issue.record("no first AU"); return }
        _ = a.ingest(packet(seq: 10, ts: 1, marker: false, payload: f1), arrivalNanos: 0)   // 6–9 and its marker lost
        #expect(a.poll(now: 150_000_000).isEmpty)
        guard case .lost(_, 1, let reason)? = a.poll(now: 210_000_000).first else { Issue.record("no expiry"); return }
        #expect(reason == "RTP marker timeout")
        let out = a.ingest(packet(seq: 40, ts: 2, marker: true, payload: [0x28, 0x01, 0x00, 0x09] + slice[2...]),
                           arrivalNanos: 220_000_000)
        guard case .accessUnit(let au)? = out.first else { Issue.record("next AU dropped"); return }
        #expect(au.containsIRAP && au.donl == 9)
    }

    @Test func truncatedFragmentIsNeverEmitted() {
        #expect(HEVCAssembler.reassemble([Data([0x62, 0x01, 0x81, 0, 1, 9, 9])]) == nil)   // start without end
    }
}

@Suite("Control parsing")
struct ControlParsingTests {
    private func fbu(_ rects: [(Int32, [UInt8])]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(UInt16(rects.count))
        for (enc, body) in rects { w.zeros(8); w.i32(enc); w.append(body) }
        return w.bytes
    }

    @Test func parsesMediaLayoutAndCursorRects() throws {
        var msg1 = [UInt8](repeating: 0, count: 24)
        msg1[1] = 1; msg1[8] = 0x17; msg1[9] = 0x0C; msg1[14] = 0x17; msg1[15] = 0x0D
        var layout = [UInt8](repeating: 0, count: 20)
        layout.putU16(1164, at: 2); layout.putU16(600, at: 4); layout.putU16(2328, at: 6); layout.putU16(1200, at: 8)
        let cursor: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 3, 9, 9, 9]
        let b = fbu([(1010, [0, 24] + msg1), (1105, [0, 20] + layout), (1104, cursor)])
        guard case .complete(.framebufferUpdate(let rects), let n) = try ServerMessageParser.parse(b)
        else { Issue.record("not parsed"); return }
        #expect(n == b.count && rects.count == 3)
        #expect(MediaStreamMessage(rects[0].body)?.ports?.video == 5901)
        #expect(DisplayLayout(rects[1].body) == DisplayLayout(layout))
        #expect(DisplayLayout(layout)?.backingWidth == 2328)
    }

    @Test func truncatedUpdateNeedsMore() throws {
        let b = fbu([(1010, [0, 50, 1, 2])])
        guard case .needMore = try ServerMessageParser.parse(b) else { Issue.record("expected needMore"); return }
    }

    /// No record boundary is trusted as a message boundary: an encoding without
    /// a known length is an explicit failure, never a silent skip.
    @Test func undelimitableEncodingFailsExplicitly() {
        let b = fbu([(1109, [0, 1, 7]), (4242, [1, 2, 3, 4])])
        #expect(throws: WireError.invalid("undelimitable framebuffer encoding 4242")) { _ = try ServerMessageParser.parse(b) }
        let announcedWithoutGrammar = fbu([(1100, [0, 0])])
        #expect(throws: WireError.invalid("undelimitable framebuffer encoding 1100")) {
            _ = try ServerMessageParser.parse(announcedWithoutGrammar)
        }
    }

    @Test func unknownMessageTypeFailsExplicitly() {
        #expect(throws: WireError.invalid("undelimitable server message type 0x7e")) {
            _ = try ServerMessageParser.parse([0x7E, 0, 0, 4, 1, 2, 3, 4])
        }
    }

    /// A message split across records completes by its own grammar and leaves
    /// the following message (in the same record) to the next parse.
    @Test func messageAcrossRecordsIsDelimitedByItsGrammar() throws {
        var msg1 = [UInt8](repeating: 0, count: 24)
        msg1[1] = 1
        let update = fbu([(1010, [0, 24] + msg1)])
        let heartbeat: [UInt8] = [0x14, 0, 0, 4, 0, 1, 0, 4]
        guard case .needMore = try ServerMessageParser.parse(Array(update.prefix(20))) else { Issue.record("expected needMore"); return }
        let joined = update + heartbeat
        guard case .complete(.framebufferUpdate(let rects), let n) = try ServerMessageParser.parse(joined)
        else { Issue.record("not parsed"); return }
        #expect(rects.count == 1 && n == update.count)
        guard case .complete(.miscStatus(4, _), 8) = try ServerMessageParser.parse(Array(joined[n...]))
        else { Issue.record("following message lost"); return }
    }

    @Test func invalidNegotiatedPortIsAControlledError() throws {
        #expect(throws: SessionFailure.self) { _ = try MediaTransport.endpointPort(0, "video") }
        #expect(try MediaTransport.endpointPort(5901, "video").rawValue == 5901)
    }

    @Test func oversizedLengthsAreRejected() {
        #expect(throws: WireError.self) { _ = try ServerMessageParser.parse([0x03, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF]) }
    }

    @Test func miscStatusHeartbeat() throws {
        guard case .complete(.miscStatus(4, _), 8) = try ServerMessageParser.parse([0x14, 0, 0, 4, 0, 1, 0, 4])
        else { Issue.record("not parsed"); return }
    }
}

@Suite("Media offer")
struct MediaOfferTests {
    /// Verifies serialized HEVC-only video and audio-off MediaBlob payloads against reference vectors.
    @Test func mediaBlobsMatchOracle() {
        #expect(MediaOffer.mediaBlob(video: true, sessionID: 0x1122_3344, clientName: "Vicinia-Test 0.1.0",
                                     timestampNanos: 1_700_000_000_000_000_000) == OracleVectors.mediaBlobVideo)
        #expect(MediaOffer.mediaBlob(video: false, sessionID: 0x5566_7788, clientName: "Vicinia-Test 0.1.0",
                                     timestampNanos: 1_700_000_000_000_000_000) == OracleVectors.mediaBlobAudio)
    }

    @Test func offerLayoutAndFlags() throws {
        let o = try MediaOffer.make(clientName: "Vicinia 0.1", hardwareModel: "iPhone18,4", osBuild: "24B156")
        let m = o.message
        #expect(m[0] == 0x1C)
        let audio = Int(m[10]) << 8 | Int(m[11]), video = Int(m[12]) << 8 | Int(m[13])
        #expect(Int(m[2]) << 8 | Int(m[3]) == audio + video + 0xD8 && m.count == audio + video + 0xD8 + 4)
        #expect(Array(m[4..<10]) == [0, 3, 0, 0, 0, 5])                          // version 3, flags BE 0x05
        #expect(Array(m[0x24..<0x52]) == o.keys.audioToHost && Array(m[0x52..<0x80]) == o.keys.audioFromHost)
        let vo = 0x80 + audio
        #expect(Array(m[vo..<vo + 46]) == o.keys.videoToHost && Array(m[vo + 46..<vo + 92]) == o.keys.videoFromHost)
        #expect(Set([o.keys.audioToHost, o.keys.audioFromHost, o.keys.videoToHost, o.keys.videoFromHost]).count == 4)
    }

    @Test func canvasFromEmbeddedAnswer() throws {
        let pb: [UInt8] = [0x2A, 8, 0x20, 0x98, 0x12, 0x28, 0xB0, 0x09, 0x30, 0x04]   // F5 {4:2328, 5:1200, 6:4}
        let dict: [String: Any] = ["avcMediaStreamNegotiatorMediaBlob": Data(try zlibCompress(pb))]
        let plist = [UInt8](try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0))
        let body = [0, 2, 0, 1, 0, 0, 0, 0] + plist + [0xEE, 0xEE, 0xEE]
        let c = MediaOffer.canvas(inAnswer: body)
        #expect(c?.0 == 2328 && c?.1 == 1200 && c?.2 == 4)
    }
}

// MARK: - Test helpers

/// Records values from escaping callbacks (any thread).
final class Recorder<T: Sendable>: Sendable {
    private let values = Mutex<[T]>([])
    func add(_ v: T) { values.withLock { $0.append(v) } }
    var all: [T] { values.withLock { $0 } }
}

/// Four stripes on four SSRCs with one global DONL.
@Suite("Decode order across stripes")
struct DecodeOrderTests {
    private static let ssrcs: [UInt32] = [0x20, 0x21, 0x22, 0x23]

    private func packet(stripe: Int, seq: UInt16, ts: UInt32, marker: Bool, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(ts); w.u32(Self.ssrcs[stripe]); w.append(payload)
        return Data(w.bytes)
    }
    private func single(type: UInt8, donl: UInt16) -> [UInt8] {
        [type << 1, 0x01, UInt8(donl >> 8), UInt8(donl & 0xFF)] + (0..<16).map { UInt8($0) }
    }
    private func fu(type: UInt8, donl: UInt16, start: Bool, end: Bool) -> [UInt8] {
        [0x62, 0x01, (start ? 0x80 : 0) | (end ? 0x40 : 0) | type, UInt8(donl >> 8), UInt8(donl & 0xFF)]
            + (0..<16).map { UInt8($0) }
    }
    private func au(stripe: Int, ts: UInt32, donl: UInt16, irap: Bool = false) -> AccessUnit {
        AccessUnit(stripe: stripe, ssrc: Self.ssrcs[stripe], rtpTimestamp: ts, firstSequence: 0, lastSequence: 0,
                   donl: donl, nalUnits: [Data([(irap ? 20 : 1) << 1, 0x01, 0xAA])], completedNanos: 0)
    }
    private func decoded(_ events: [DecodeOrderBuffer.Event]) -> [UInt16] {
        events.compactMap { if case .decode(let a) = $0 { a.donl } else { nil } }
    }

    /// Stripe 0 of update B waits for a reordered fragment while stripes 1 and 3
    /// complete first; the decoder must still receive B in DONL order, across
    /// the DONL 65535→0 and RTP sequence 65535→0 wraps.
    @Test func accessUnitsCompletingOutOfDecodeOrderAreReleasedInDONLOrder() {
        let map = Dictionary(uniqueKeysWithValues: Self.ssrcs.enumerated().map { ($1, $0) })
        let asm = HEVCAssembler(stripeForSSRC: { map[$0] })
        var order = DecodeOrderBuffer()
        var completed: [UInt16] = [], released: [UInt16] = []
        func feed(_ d: Data, _ t: UInt64) {
            for case .accessUnit(let a) in asm.ingest(d, arrivalNanos: t) {
                completed.append(a.donl!)
                released += decoded(order.push(a, now: t))
            }
        }
        // Update A (ts 1000): IDR on stripe 0, all stripes, in order.
        feed(packet(stripe: 0, seq: 65_534, ts: 1000, marker: true, payload: single(type: 20, donl: 65_532)), 0)
        feed(packet(stripe: 1, seq: 100, ts: 1000, marker: true, payload: single(type: 1, donl: 65_533)), 1)
        feed(packet(stripe: 2, seq: 200, ts: 1000, marker: true, payload: single(type: 1, donl: 65_534)), 2)
        feed(packet(stripe: 3, seq: 300, ts: 1000, marker: true, payload: single(type: 1, donl: 65_535)), 3)
        #expect(released == [65_532, 65_533, 65_534, 65_535])
        // Update B (ts 1400, partial: stripe 2 unchanged): stripe 0's last fragment is late.
        feed(packet(stripe: 0, seq: 65_535, ts: 1400, marker: false, payload: fu(type: 1, donl: 0, start: true, end: false)), 10)
        feed(packet(stripe: 1, seq: 101, ts: 1400, marker: true, payload: single(type: 1, donl: 1)), 11)
        feed(packet(stripe: 3, seq: 301, ts: 1400, marker: true, payload: single(type: 1, donl: 2)), 12)
        #expect(released.count == 4)                                 // B's stripes 1 and 3 are held
        feed(packet(stripe: 0, seq: 0, ts: 1400, marker: true, payload: fu(type: 1, donl: 0, start: false, end: true)), 13)
        #expect(completed == [65_532, 65_533, 65_534, 65_535, 1, 2, 0])  // arrival/completion order
        #expect(released == [65_532, 65_533, 65_534, 65_535, 0, 1, 2])  // decode order
        #expect(order.heldCount == 0)
    }

    /// A picture that never arrives is a gap after the wait: the held successor
    /// is never decoded and release restarts at the next IRAP.
    @Test func missingPictureIsAGapThenRealignsAtIRAP() {
        var order = DecodeOrderBuffer()
        #expect(decoded(order.push(au(stripe: 1, ts: 5, donl: 9), now: 0)).isEmpty)   // before random access
        #expect(decoded(order.push(au(stripe: 0, ts: 10, donl: 10, irap: true), now: 0)) == [10])
        #expect(decoded(order.push(au(stripe: 1, ts: 10, donl: 11), now: 0)) == [11])
        #expect(decoded(order.push(au(stripe: 1, ts: 20, donl: 13), now: 1_000_000)).isEmpty)   // 12 missing
        #expect(order.poll(now: 15_000_000).isEmpty)
        let expired = order.poll(now: 21_000_000)
        guard case .gap(12)? = expired.first else { Issue.record("no gap"); return }
        #expect(decoded(expired).isEmpty && order.next == nil)
        #expect(decoded(order.push(au(stripe: 2, ts: 20, donl: 14), now: 22_000_000)).isEmpty)
        let restart = order.push(au(stripe: 0, ts: 30, donl: 15, irap: true), now: 23_000_000)
        #expect(decoded(restart) == [15])
        #expect(restart.filter { if case .skip = $0 { true } else { false } }.count == 2)    // 13 and 14 dropped
    }
}

@Suite("Desktop update contract")
struct DesktopUpdateTests {
    private let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 64, canvasHeight: 64,
                                      pictureWidth: 64, pictureHeight: 16, cropTop: 0, visibleHeight: 16)
    private let buffer: CVPixelBuffer = {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }()
    private func picture(_ stripe: Int, ts: UInt32, gen: UInt64 = 1) -> DecodedStripe {
        DecodedStripe(pixelBuffer: buffer, stripe: stripe, rtpTimestamp: ts, generation: gen, auSequence: 0,
                      submitNanos: 0, decodedNanos: 0)
    }
    private func mailbox() -> DesktopUpdateMailbox {
        let m = DesktopUpdateMailbox()
        m.reset(generation: 1, layout: layout)
        return m
    }
    private func submit(_ m: DesktopUpdateMailbox, _ ts: UInt32, _ stripes: [Int]) {
        for s in stripes { m.noteSubmitted(stripe: s, rtpTimestamp: ts, generation: 1) }
    }

    /// The last stripe index decoding first must not commit while earlier
    /// members of the same update are still being decoded.
    @Test func lastStripeFirstWaitsForEveryMember() {
        let m = mailbox()
        submit(m, 100, [0, 1, 2, 3])
        for s in [3, 0, 1] { m.deliver(picture(s, ts: 100)) }
        #expect(m.take() == nil)
        m.deliver(picture(2, ts: 100))
        let snap = m.take()
        #expect(snap?.rtpTimestamp == 100 && snap?.changedStripes == [0, 1, 2, 3])
        #expect(m.counters.committedUnique == 1 && m.counters.splitCommits == 0)
    }

    /// Decoder callbacks out of order still commit in decode order; a late
    /// callback of an abandoned (lost) update never overwrites newer content.
    @Test func outOfOrderAndLateCallbacksNeverOverwriteNewerContent() {
        let m = mailbox()
        // These regions must already be initialized in this generation before
        // the partial updates below can preserve them (initial barrier).
        submit(m, 50, [2, 3])
        m.deliver(picture(2, ts: 50)); m.deliver(picture(3, ts: 50))
        submit(m, 100, [0, 1])
        submit(m, 200, [0])                          // newer timestamp: update 100 is final
        m.deliver(picture(0, ts: 200))
        #expect(m.take() == nil)                     // 100 still incomplete: 200 must wait
        m.deliver(picture(0, ts: 100))
        m.deliver(picture(1, ts: 100))
        m.noteFinal(rtpTimestamp: 200, generation: 1)
        let snap = m.take()
        #expect(snap?.rtpTimestamp == 200)
        #expect(snap?.stripes[0]?.rtpTimestamp == 200 && snap?.stripes[1]?.rtpTimestamp == 100)
        submit(m, 300, [0])
        m.noteAbandoned(rtpTimestamp: 300, generation: 1)        // its stripe was lost
        m.deliver(picture(0, ts: 300))                           // late callback of the abandoned update
        m.deliver(picture(0, ts: 100))                           // stale duplicate
        submit(m, 400, [1])
        m.noteFinal(rtpTimestamp: 400, generation: 1)
        m.deliver(picture(1, ts: 400))
        let next = m.take()
        #expect(next?.stripes[0]?.rtpTimestamp == 200 && next?.stripes[1]?.rtpTimestamp == 400)
        let c = m.counters
        #expect(c.committedUnique == 3 && c.orphanedStripes == 2 && c.discardedIncomplete == 1 && c.supersededUnpresented == 1)
    }

    /// A settled partial update commits without waiting for absent stripes; an
    /// update with a failed member is discarded instead of presented.
    @Test func partialUpdateCommitsAndFailedUpdateIsDiscarded() {
        let m = mailbox()
        submit(m, 50, [1, 3])
        m.deliver(picture(1, ts: 50)); m.deliver(picture(3, ts: 50))
        submit(m, 100, [0, 2])
        m.deliver(picture(0, ts: 100)); m.deliver(picture(2, ts: 100))
        #expect(m.take() == nil)                                 // stripe 3 might still come
        m.noteFinal(rtpTimestamp: 100, generation: 1)
        #expect(m.take()?.changedStripes == [0, 2])
        submit(m, 200, [0, 1])
        m.noteFailed(stripe: 1, rtpTimestamp: 200, generation: 1)
        m.deliver(picture(0, ts: 200))
        m.noteFinal(rtpTimestamp: 200, generation: 1)
        #expect(m.take() == nil)
        let c = m.counters
        #expect(c.committedUnique == 1 && c.committedPartial == 1 && c.discardedIncomplete == 1)
    }

    /// A stream reset voids an untaken committed desktop and older callbacks.
    @Test func generationResetVoidsCommittedSnapshotAndOldCallbacks() {
        let m = mailbox()
        submit(m, 100, [0, 1, 2, 3])
        for s in 0..<4 { m.deliver(picture(s, ts: 100)) }
        m.reset(generation: 2, layout: layout)
        #expect(m.take() == nil && !m.isCurrent(generation: 1) && m.isCurrent(generation: 2))
        m.deliver(picture(0, ts: 100, gen: 1))
        #expect(m.counters.staleGenerationDrops == 1)
    }

    /// Neither the last stripe nor the settle heuristic proves initial coverage.
    /// Static regions are usable only after actual decode in the new generation.
    @Test func newGeometryWaitsForEveryInitialRegion() {
        let m = mailbox()
        submit(m, 100, [0, 3])
        m.deliver(picture(0, ts: 100)); m.deliver(picture(3, ts: 100))
        #expect(m.take() == nil && m.counters.committedUnique == 0)
        submit(m, 200, [1]); m.noteFinal(rtpTimestamp: 200, generation: 1)
        m.deliver(picture(1, ts: 200))
        #expect(m.take() == nil)
        submit(m, 300, [2]); m.noteFinal(rtpTimestamp: 300, generation: 1)
        m.deliver(picture(2, ts: 300))
        let desktop = m.take()
        #expect(desktop?.rtpTimestamp == 300 && desktop?.stripes.compactMap { $0 }.count == 4)
        m.reset(generation: 2, layout: layout)
        m.noteSubmitted(stripe: 3, rtpTimestamp: 400, generation: 2)
        m.deliver(picture(3, ts: 400, gen: 2))
        #expect(m.take() == nil)      // cannot borrow the other regions from generation 1
    }

    /// The lost picture belongs to update 100, although update 200 is now open.
    /// Its late callback/members cannot resurrect it or initialize a new desktop.
    @Test func lossInvalidatesAffectedUpdateEvenAfterNewerSubmission() {
        let m = mailbox()
        submit(m, 100, [0, 1, 2, 3])
        for s in 0..<3 { m.deliver(picture(s, ts: 100)) }
        submit(m, 200, [0])
        m.deliver(picture(0, ts: 200))
        m.noteAbandoned(rtpTimestamp: 100, generation: 1)
        m.deliver(picture(3, ts: 100))
        submit(m, 100, [3])          // a later stripe of the lost update
        m.deliver(picture(3, ts: 100))
        m.noteFinal(rtpTimestamp: 200, generation: 1)
        #expect(m.take() == nil)
        submit(m, 300, [0, 1, 2, 3])
        for s in 0..<4 { m.deliver(picture(s, ts: 300)) }
        #expect(m.take()?.stripes.allSatisfy { $0?.rtpTimestamp == 300 } == true)
    }

    @Test func failedPictureCannotBeResurrectedByALateMember() {
        let m = mailbox()
        submit(m, 50, [0, 1, 2, 3])
        for s in 0..<4 { m.deliver(picture(s, ts: 50)) }
        _ = m.take()
        submit(m, 100, [0, 1])
        m.deliver(picture(0, ts: 100))
        m.noteFailed(stripe: 1, rtpTimestamp: 100, generation: 1)
        m.noteFinal(rtpTimestamp: 100, generation: 1)
        #expect(m.take() == nil)
        submit(m, 100, [3])               // the late last stripe cannot make a failed timestamp usable
        m.deliver(picture(3, ts: 100))
        #expect(m.take() == nil)
        submit(m, 200, [0, 1, 2, 3])
        for s in 0..<4 { m.deliver(picture(s, ts: 200)) }
        #expect(m.take()?.rtpTimestamp == 200)
    }

    @Test func lossInvalidatesSnapshotsAlreadyHandedToRenderer() throws {
        let m = mailbox()
        submit(m, 100, [0, 1, 2, 3])
        for s in 0..<4 { m.deliver(picture(s, ts: 100)) }
        let valid = try #require(m.take())
        submit(m, 200, [0]); m.noteFinal(rtpTimestamp: 200, generation: 1)
        m.deliver(picture(0, ts: 200))
        let affected = try #require(m.take())
        // A later partial desktop inherits stripe 0 of the affected update.
        submit(m, 300, [1]); m.noteFinal(rtpTimestamp: 300, generation: 1)
        m.deliver(picture(1, ts: 300))
        let inherited = try #require(m.take())
        #expect(m.isCurrent(affected) && m.isCurrent(inherited))
        m.noteAbandoned(rtpTimestamp: 200, generation: 1)
        #expect(m.isCurrent(generation: 1))              // still the same media generation
        #expect(!m.isCurrent(affected) && !m.isCurrent(inherited))
        #expect(m.isCurrent(valid))                     // previous valid desktop remains usable
    }
}

@Suite("Live media timeouts", .serialized)
struct LiveTimeoutTests {
    /// No packet follows an incomplete AU: the live poll on the media queue
    /// expires it and requests recovery (nothing is decoded).
    @Test func livePollExpiresIncompleteAUAndRequestsRecovery() async throws {
        let pipeline = MediaPipeline(ssrcToStripe: [0x10: 0], canvas: (64, 16), ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let requests = Recorder<Int>()
        let first: [UInt8] = [0x62, 0x01, 0x80 | 1, 0x00, 0x03] + [UInt8](repeating: 7, count: 20)
        let last: [UInt8] = [0x62, 0x01, 0x40 | 1, 0x00, 0x03] + [UInt8](repeating: 7, count: 20)
        func rtp(_ seq: UInt16, _ marker: Bool, _ payload: [UInt8]) -> Data {
            var w = ByteWriter()
            w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(4000); w.u32(0x10); w.append(payload)
            return Data(w.bytes)
        }
        pipeline.queue.sync {
            pipeline.onRecoveryNeeded = { stripe in requests.add(stripe) }
            pipeline.startPolling()
            let now = DispatchTime.now().uptimeNanoseconds
            pipeline.ingest(rtp(1, false, first), arrival: now)
            pipeline.ingest(rtp(3, true, last), arrival: now)        // seq 2 never arrives
        }
        try await Task.sleep(for: .milliseconds(80))
        let c = pipeline.queue.sync { pipeline.stopPolling(); return pipeline.counters.snapshot }
        #expect(c.lostAUs == 1 && c.lossReasons["sequence gap"] == 1)
        #expect(c.recoveryRequests == 1 && requests.all == [0])
        #expect(c.decodeSubmitted == 0)
    }
}

@Suite("Session lifecycle", .serialized)
struct SessionLifecycleTests {
    /// Closed before its startup task ran: the session never connects and
    /// never asks for trust.
    @Test func disconnectBeforeRunNeverConnects() async throws {
        let host = try FakeHost(behavior: .valid)
        let port = try await host.start()
        defer { host.stop() }
        let phases = Recorder<SessionPhase>()
        let prompts = Recorder<String>()
        let config = SessionConfiguration(host: "127.0.0.1", port: port, username: "u", logicalWidth: 1164,
                                          logicalHeight: 600, hardwareModel: "test", osBuild: "test", osVersion: (27, 2, 1))
        let session = HPSSSession(
            config: config, password: SecretBytes("correct horse"),
            pipeline: MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                    mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog()),
            evidence: EvidenceLog(),
            trust: { host, _ in prompts.add(host); return true },
            onPhase: { p, _ in phases.add(p) })
        await session.disconnect()
        await session.run()
        #expect(!phases.all.contains(.connecting))
        #expect(prompts.all.isEmpty)
    }
}
