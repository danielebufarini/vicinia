// Vicinia tests — control record layer and SRTP/SRTCP protection.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

@Suite("Record layer")
struct RecordLayerTests {
    /// Reference encrypted records open and authenticate with the native record layer.
    @Test func opensOracleRecords() throws {
        let rl = try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey)
        var r = ByteReader(OracleVectors.recordWire)
        var messages: [[UInt8]] = []
        while r.remaining > 0 {
            let n = Int(try r.u16())
            messages.append(try rl.open(try r.take(n)))
        }
        #expect(messages == OracleVectors.recordMessages)
        #expect(rl.receiveSequence == 2)
    }

    private func pair() throws -> (RecordLayer, RecordLayer) {
        (try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey),
         try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey))
    }

    private func records(_ wire: [UInt8]) throws -> [[UInt8]] {
        var r = ByteReader(wire), out: [[UInt8]] = []
        while r.remaining > 0 { out.append(try r.take(Int(try r.u16()))) }
        return out
    }

    @Test func roundTripIncludingMultiRecordSplit() throws {
        let (a, b) = try pair()
        let big = [UInt8](repeating: 0x5A, count: 70_000)
        let recs = try records(try a.seal([0x14, 0, 0, 4, 0, 1, 0, 4]) + a.seal(big))
        #expect(recs.count == 3)
        #expect(try b.open(recs[0]) == [0x14, 0, 0, 4, 0, 1, 0, 4])
        #expect(try b.open(recs[1]) + b.open(recs[2]) == big)
    }

    @Test func alteredRecordIsFatal() throws {
        let (a, b) = try pair()
        var rec = try records(try a.seal([1, 2, 3]))[0]
        rec[rec.count - 1] ^= 0x01
        #expect(throws: RecordError.integrity(seq: 0)) { _ = try b.open(rec) }
    }

    @Test func outOfSequenceRecordIsFatal() throws {
        let (a, b) = try pair()
        _ = try a.seal([1])                                   // record 0 never delivered
        let second = try records(try a.seal([2]))[0]
        #expect(throws: RecordError.integrity(seq: 0)) { _ = try b.open(second) }
    }

    @Test(arguments: [0, 16, 17, 31, 65_536])
    func invalidFramingIsFatal(_ n: Int) {
        #expect(throws: RecordError.framing(n)) { try RecordLayer.validateLength(n) }
    }

    @Test func rekeyRotationKeepsBothSidesAligned() throws {
        let (a, b) = try pair()
        _ = try b.open(try records(try a.seal([9]))[0])
        let next = [0, 0, 0, 2] + [UInt8](repeating: 7, count: 32)
        try a.rotate(rekey: next); try b.rotate(rekey: next)
        #expect(try b.open(try records(try a.seal([8, 8]))[0]) == [8, 8])
        #expect(a.sendSequence == 2 && b.receiveSequence == 2)
        #expect(throws: RecordError.rekey) { try a.rotate(rekey: [1, 2, 3]) }
    }
}

@Suite("SRTP / SRTCP")
struct SRTPTests {
    let key = (0..<46).map { UInt8($0) }

    private func rtp(seq: UInt16, ssrc: UInt32 = 0x561B_778A) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x80); w.u8(100); w.u16(seq); w.u32(1000); w.u32(ssrc)
        w.append([0x40, 0x01, 0x00, 0x05, 1, 2, 3, 4])
        return w.bytes
    }

    @Test func roundTripAcrossSequenceWrap() throws {
        let tx = try SRTPSession(keySalt: key, inbound: false), rx = try SRTPSession(keySalt: key, inbound: true)
        for seq: UInt16 in [65_533, 65_534, 65_535, 0, 1, 2] {
            #expect([UInt8](try rx.unprotectRTP(try tx.protectRTP(rtp(seq: seq)))) == rtp(seq: seq))
        }
    }

    @Test func tamperedPacketFailsAuthentication() throws {
        let tx = try SRTPSession(keySalt: key, inbound: false), rx = try SRTPSession(keySalt: key, inbound: true)
        var p = [UInt8](try tx.protectRTP(rtp(seq: 10)))
        p[14] ^= 0xFF
        #expect(throws: SRTPError.authentication) { _ = try rx.unprotectRTP(Data(p)) }
    }

    @Test func replayedPacketIsRejected() throws {
        let tx = try SRTPSession(keySalt: key, inbound: false), rx = try SRTPSession(keySalt: key, inbound: true)
        let p = try tx.protectRTP(rtp(seq: 20))
        _ = try rx.unprotectRTP(p)
        #expect(throws: SRTPError.replay) { _ = try rx.unprotectRTP(p) }
    }

    @Test func wrongLegKeyIsRejected() throws {
        let tx = try SRTPSession(keySalt: key, inbound: false)
        let rx = try SRTPSession(keySalt: key.map { $0 ^ 0x55 }, inbound: true)
        #expect(throws: SRTPError.authentication) { _ = try rx.unprotectRTP(try tx.protectRTP(rtp(seq: 1))) }
    }

    @Test func srtcpAuthenticationAndReplay() throws {
        let tx = try SRTPSession(keySalt: key, inbound: false), rx = try SRTPSession(keySalt: key, inbound: true)
        let rr = RTCPBuild.rr(sender: 0x1234_5678, sources: [(0x561B_778A, 7, 0, 0)])
        let p = try tx.protectRTCP(rr)
        #expect([UInt8](try rx.unprotectRTCP(p)) == rr)
        #expect(throws: SRTPError.replay) { _ = try rx.unprotectRTCP(p) }
        var t = [UInt8](try tx.protectRTCP(rr)); t[9] ^= 1
        #expect(throws: SRTPError.authentication) { _ = try rx.unprotectRTCP(Data(t)) }
    }

    @Test func rctlLayout() {
        let p = RTCPBuild.rctl(sender: 0xA, echoTimestamp: 0x1234_5600, holdMs: 3, clockSeconds: 2, delaySeconds: 0.5,
                               received: 4097, bandwidthKbps: 60_000)
        #expect(p.count == 32)
        #expect(Array(p[0..<4]) == [0x80, 204, 0, 7])
        #expect(Array(p[8..<12]) == Array("RCTL".utf8))
        #expect(Array(p[12..<16]) == [0x85, 0, 0, 4])
        #expect(Array(p[16..<18]) == [0x34, 0x56])                    // echo ts >> 8
        #expect(Array(p[28..<30]) == [0x00, 0x01])                    // received mod 4096
    }
}
