// Vicinia tests — video-answer LTRP flag and LTRP acknowledgments.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import VideoToolbox
@testable import Vicinia

/// Media-stream message 2 (answer) as the host lays it out: big-endian kind 2,
/// the audio, video and second-video blob lengths at offsets 8, 10 and 12,
/// the blobs from offset 18 in that order, each a binary property list whose
/// `avcMediaStreamNegotiatorMediaBlob` is a zlib-compressed protobuf.
enum SyntheticAnswer {
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        while v > 0x7F { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }
    static func field(_ n: UInt64, _ v: UInt64) -> [UInt8] { varint(n << 3) + varint(v) }
    static func message(_ n: UInt64, _ body: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(UInt64(body.count)) + body }

    /// Audio answer: the stream description is field 3 (3.1 = the host's audio SSRC).
    static func audioBlob(ssrc: UInt64 = 4_229_238_303, extra: [UInt8] = []) -> [UInt8] {
        field(1, 1) + field(2, 1) + message(3, field(1, ssrc) + field(4, 5632) + field(5, 1536) + extra) + field(14, 2)
    }
    /// Video answer: the stream description is field 5 (canvas 5.4/5.5, tiles 5.6, LTRP 5.7 when given).
    static func videoBlob(ltrp: UInt64?, width: UInt64 = 2752, height: UInt64 = 1998) -> [UInt8] {
        let stream = field(1, 1_461_739_152) + field(4, width) + field(5, height) + field(6, 4) + (ltrp.map { field(7, $0) } ?? [])
        return field(1, 1) + field(2, 1) + message(5, stream) + field(14, 2)
    }
    static func plist(_ blob: [UInt8], mode: Int) throws -> [UInt8] {
        [UInt8](try PropertyListSerialization.data(fromPropertyList: [
            "avcMediaStreamNegotiatorMediaBlob": Data(try zlibCompress(blob)),
            "avcMediaStreamNegotiatorMode": mode,
        ], format: .binary, options: 0))
    }
    static func body(audio: [UInt8], video: [UInt8], video2: [UInt8] = [], declared: (Int, Int, Int)? = nil) -> [UInt8] {
        let (a, v, v2) = declared ?? (audio.count, video.count, video2.count)
        var header = [UInt8](repeating: 0, count: 18)
        header[1] = 2
        for (offset, n) in [(8, a), (10, v), (12, v2)] { header[offset] = UInt8(n >> 8); header[offset + 1] = UInt8(n & 0xFF) }
        return header + audio + video + video2
    }
    /// Adjacent audio and video answers as laid out by the host.
    static func adjacent(ltrp: UInt64?) throws -> [UInt8] {
        body(audio: try plist(audioBlob(), mode: 8), video: try plist(videoBlob(ltrp: ltrp), mode: 7))
    }
}

/// Minimal synthetic HEVC-over-RTP packet builders used by pipeline LTRP tests.
private enum SyntheticHEVCRTP {
    static func vcl(type: UInt8) -> [UInt8] {
        [type << 1, 0x01, 0xAF, 0x09, 0x40, 0xC0]
    }

    static func rtp(ssrc: UInt32, seq: UInt16, ts: UInt32, marker: Bool, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(ts); w.u32(ssrc); w.append(payload)
        return Data(w.bytes)
    }

    static func single(_ nal: [UInt8], donl: UInt16) -> [UInt8] {
        Array(nal[0..<2]) + [UInt8(donl >> 8), UInt8(donl & 0xFF)] + Array(nal[2...])
    }

    static func aggregation(_ nals: [[UInt8]], donl: UInt16) -> [UInt8] {
        var out: [UInt8] = [48 << 1, 0x01, UInt8(donl >> 8), UInt8(donl & 0xFF)]
        for n in nals { out += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n }
        return out
    }
}

@Suite("Video answer LTRP flag")
struct VideoAnswerLTRPTests {
    typealias A = SyntheticAnswer

    @Test func videoFlagIsEnabledDisabledOrAbsent() throws {
        #expect(MediaOffer.videoLTRP(inAnswer: try A.adjacent(ltrp: 1)) == .enabled)
        #expect(MediaOffer.videoLTRP(inAnswer: try A.adjacent(ltrp: 7)) == .enabled)              // any non-zero value
        #expect(MediaOffer.videoLTRP(inAnswer: try A.adjacent(ltrp: 0)) == .disabled)
        #expect(MediaOffer.videoLTRP(inAnswer: try A.adjacent(ltrp: nil)).label == "ABSENT")
    }

    /// The video blob is found by the answer's lengths, never by its content.
    @Test func audioAndSecondVideoBlobsNeverProvideTheFlag() throws {
        let audioWith7 = try A.plist(A.audioBlob(extra: A.field(7, 1)), mode: 8)
        #expect(MediaOffer.videoLTRP(inAnswer: A.body(audio: audioWith7, video: try A.plist(A.videoBlob(ltrp: nil), mode: 7))).label == "ABSENT")
        let audioLikeVideo = try A.plist(A.videoBlob(ltrp: 1), mode: 8)                         // a field 5.7 = 1 in the AUDIO blob
        #expect(MediaOffer.videoLTRP(inAnswer: A.body(audio: audioLikeVideo, video: try A.plist(A.videoBlob(ltrp: 0), mode: 7))) == .disabled)
        let audio = try A.plist(A.audioBlob(), mode: 8)
        #expect(MediaOffer.videoLTRP(inAnswer: A.body(audio: audio, video: try A.plist(A.videoBlob(ltrp: 0), mode: 7),
                                                      video2: try A.plist(A.videoBlob(ltrp: 1), mode: 7))) == .disabled)
        #expect(MediaOffer.videoLTRP(inAnswer: A.body(audio: audio, video: try A.plist(A.videoBlob(ltrp: 1), mode: 7),
                                                      video2: try A.plist(A.videoBlob(ltrp: 0), mode: 7))) == .enabled)
    }

    @Test func truncatedOrMalformedAnswersAreUnparseable() throws {
        let audio = try A.plist(A.audioBlob(), mode: 8), video = try A.plist(A.videoBlob(ltrp: 1), mode: 7)
        func label(_ b: [UInt8]) -> String { MediaOffer.videoLTRP(inAnswer: b).label }
        #expect(label(A.body(audio: audio, video: video, declared: (audio.count, video.count + 1, 0))) == "UNPARSEABLE")  // past the end
        #expect(label(Array(A.body(audio: audio, video: video).prefix(17))) == "UNPARSEABLE")                         // no header
        var kind3 = A.body(audio: audio, video: video); kind3[1] = 3
        #expect(label(kind3) == "UNPARSEABLE")                                                                     // not an answer
        #expect(label(A.body(audio: audio, video: [0x01, 0x02, 0x03, 0x04])) == "UNPARSEABLE")                     // neither plist nor zlib
        let notZlib = [UInt8](try PropertyListSerialization.data(fromPropertyList: ["avcMediaStreamNegotiatorMediaBlob": Data([9, 9, 9])],
                                                                 format: .binary, options: 0))
        #expect(label(A.body(audio: audio, video: notZlib)) == "UNPARSEABLE")
        let badTop = try zlibCompress(A.field(1, 1) + [0x2A, 0x05, 0x08])                                          // field 5 shorter than declared
        #expect(label(A.body(audio: audio, video: badTop)) == "UNPARSEABLE")
        let badStream = try zlibCompress(A.field(1, 1) + A.message(5, A.field(4, 2752) + [0x38]))                  // 5.7 tag without value
        #expect(label(A.body(audio: audio, video: badStream)) == "UNPARSEABLE")
        #expect(label(A.body(audio: audio, video: [])) == "ABSENT")                                                // no video answer
        #expect(label(A.body(audio: audio, video: try zlibCompress(A.field(1, 1) + A.field(14, 2)))) == "ABSENT")  // no stream description
    }

    /// A bare negotiator blob (offer without endpoint information) is read as well.
    @Test func bareVideoNegotiatorBlobIsRead() throws {
        let body = A.body(audio: try A.plist(A.audioBlob(), mode: 8), video: try zlibCompress(A.videoBlob(ltrp: 1)))
        #expect(MediaOffer.videoLTRP(inAnswer: body) == .enabled)
    }

    /// The production canvas parser is unchanged on the same bodies.
    @Test func canvasIsUnchangedOnAdjacentAnswers() throws {
        for ltrp: UInt64? in [1, 0, nil] {
            let c = try #require(MediaOffer.canvas(inAnswer: try A.adjacent(ltrp: ltrp)))
            #expect(c.0 == 2752 && c.1 == 1998 && c.2 == 4)
        }
    }
}

@Suite("LTRP acknowledgment packet, gate and state")
struct ReferenceAcknowledgmentStateTests {
    @Test func packetIsTheSixteenByteApplicationReport() {
        #expect(RTCPBuild.referenceAcknowledgment(sender: 0x5720_5E90, donl: 0x1234)
                == [0x80, 0xCC, 0x00, 0x03, 0x57, 0x20, 0x5E, 0x90, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x12, 0x34])
        #expect(RTCPBuild.referenceAcknowledgment(sender: 1, donl: 0xFFFF).suffix(4) == [0x00, 0x00, 0xFF, 0xFF])
        #expect(RTCPBuild.referenceAcknowledgment(sender: 1, donl: 0).suffix(4) == [0, 0, 0, 0])
    }

    @Test func gateNeedsAnEnabledVideoAnswerAndHEVC() {
        let answers: [LTRPNegotiation] = [.enabled, .disabled, .absent("x"), .unparseable("x")]
        for answer in answers {
            for codec in [VideoCodec.hevc, .other] {
                let expected = answer == .enabled && codec == .hevc
                #expect(ReferenceAcknowledgment.gate(answer: answer, codec: codec) == expected)
            }
        }
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @Test func diagnosticSwitchIsOffUnlessExplicitlyOn() {
        #expect(ReferenceAcknowledgmentControl(launchValue: nil) == .off)
        #expect(ReferenceAcknowledgmentControl(launchValue: "on") == .on)
        for other in ["off", "ON", "1", "yes", "true", ""] { #expect(ReferenceAcknowledgmentControl(launchValue: other) == .off) }
    }
    #endif

    @Test func onlyStripeZeroUnitsWithADONLAreNotedWhileActive() {
        var s = ReferenceAcknowledgment()
        s.handedToDecoding(stripe: 0, donl: 1)
        #expect(s.take() == nil && s.counters.noted == 0)                        // inactive
        s.activate(true)
        for stripe in 1...3 { s.handedToDecoding(stripe: stripe, donl: UInt16(10 + stripe)) }
        s.handedToDecoding(stripe: 0, donl: nil)
        #expect(s.take() == nil)
        s.handedToDecoding(stripe: 0, donl: 7)
        #expect(s.take() == 7)
        #expect(s.take() == nil)                                                 // never repeated
    }

    @Test func newestUnitWinsAndWrapAroundIsKept() {
        var s = ReferenceAcknowledgment()
        s.activate(true)
        s.handedToDecoding(stripe: 0, donl: 5)
        s.handedToDecoding(stripe: 0, donl: 6)
        #expect(s.take() == 6 && s.counters.superseded == 1)
        s.handedToDecoding(stripe: 0, donl: 0xFFFF)
        #expect(s.take() == 0xFFFF)
        s.handedToDecoding(stripe: 0, donl: 0)
        #expect(s.take() == 0)
        #expect(s.counters.noted == 4 && s.counters.taken == 3)
    }

    @Test func dropAndDeactivationDiscardTheWaitingUnit() {
        var s = ReferenceAcknowledgment()
        s.activate(true)
        s.handedToDecoding(stripe: 0, donl: 9)
        s.drop()
        #expect(s.take() == nil && s.counters.dropped == 1)
        s.handedToDecoding(stripe: 0, donl: 10)
        s.activate(false)
        #expect(s.take() == nil && s.counters.dropped == 2)
        s.handedToDecoding(stripe: 0, donl: 11)
        #expect(s.take() == nil)
    }
}

@Suite("LTRP acknowledgments in the media pipeline", .serialized)
struct ReferenceAcknowledgmentPipelineTests {
    private let ms: UInt64 = 1_000_000

    @Test func newestStripeZeroUnitIsFlushedOnceAtTheEndOfABatch() {
        let pipeline = MediaPipeline(ssrcToStripe: [0x10: 0], canvas: (64, 16), ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let sent = Recorder<UInt16>()
        let state = pipeline.queue.sync {
            pipeline.onReferenceAcknowledgment = { sent.add($0) }
            pipeline.noteHandedToDecoding(stripe: 0, donl: 10)               // inactive: ignored
            pipeline.poll(now: 1 * ms)
            pipeline.setReferenceAcknowledgments(active: true)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 11)
            pipeline.noteHandedToDecoding(stripe: 1, donl: 12)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 13)
            pipeline.poll(now: 2 * ms)
            pipeline.poll(now: 3 * ms)                                       // nothing new: nothing sent
            return pipeline.referenceAcknowledgmentState
        }
        #expect(sent.all == [13])
        #expect(state.active && state.counters.superseded == 1)
    }

    /// A loss in the same batch drops the unit before it is sent; so does a reset.
    @Test func lossAndResetDropTheWaitingUnit() {
        let pipeline = MediaPipeline(ssrcToStripe: [0x10: 0], canvas: (64, 16), ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let sent = Recorder<UInt16>(), requests = Recorder<Int>()
        func rtp(_ seq: UInt16, _ marker: Bool, _ fu: UInt8) -> Data {
            var w = ByteWriter()
            w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(4000); w.u32(0x10)
            w.append([0x62, 0x01, fu | 1, 0x00, 0x03] + [UInt8](repeating: 7, count: 20))
            return Data(w.bytes)
        }
        let state = pipeline.queue.sync {
            pipeline.onReferenceAcknowledgment = { sent.add($0) }
            pipeline.onRecoveryNeeded = { requests.add($0) }
            pipeline.setReferenceAcknowledgments(active: true)
            pipeline.ingest(rtp(1, false, 0x80), arrival: 0)
            pipeline.ingest(rtp(3, true, 0x40), arrival: 0)                  // sequence 2 never arrives
            pipeline.noteHandedToDecoding(stripe: 0, donl: 20)
            pipeline.poll(now: 30 * ms)                                      // the gap expires: loss, recovery
            pipeline.noteHandedToDecoding(stripe: 0, donl: 21)
            pipeline.resetStream()                                           // reconnect / resize
            pipeline.poll(now: 31 * ms)
            return pipeline.referenceAcknowledgmentState
        }
        #expect(requests.all == [0])
        #expect(sent.all.isEmpty)
        #expect(state.counters.dropped == 2 && state.counters.taken == 0)
        #expect(state.active)                                                // a reset keeps the offer's decision
    }

    /// A parameter-set change rebuilds the decoder (new
    /// generation, random access awaited). A unit handed to the previous
    /// decoder earlier in the same batch must not be confirmed afterwards.
    @Test func parameterSetChangeDropsTheWaitingUnitOfThePreviousGeneration() {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [0x10: 0], canvas: (64, 16), ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let sent = Recorder<UInt16>()
        // New VPS/SPS/PPS with an IDR (so decode order releases it to `submit`); the SPS is too short to parse,
        // so the rebuilt decoder does not come up and the unit is withheld, as on any rebuild failure.
        let nals: [[UInt8]] = [[32 << 1, 1, 0x0C, 0x01], [33 << 1, 1, 0x01], [34 << 1, 1, 0xC1], [20 << 1, 1, 0xAF, 0x09]]
        let state = pipeline.queue.sync {
            pipeline.onReferenceAcknowledgment = { sent.add($0) }
            pipeline.setReferenceAcknowledgments(active: true)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 0x0101)          // handed to the decoder of this generation
            pipeline.ingest(SyntheticHEVCRTP.rtp(ssrc: 0x10, seq: 7, ts: 4000, marker: true,
                                                 payload: SyntheticHEVCRTP.aggregation(nals, donl: 0x0102)), arrival: 1_000_000)
            return pipeline.referenceAcknowledgmentState
        }
        #expect(evidence.value("sps.parseError.gen1") != nil)                // the decoder was rebuilt (new generation)
        #expect(sent.all.isEmpty)
        #expect(state.counters.dropped == 1 && state.counters.taken == 0)
    }

    /// Units that arrive and are released in decode order but never reach the
    /// decoder (here: no parameter sets, so no decoder) are never confirmed.
    @Test func unitsWithheldFromTheDecoderAreNeverConfirmed() {
        let ssrcs: [UInt32] = [0x30, 0x31, 0x32, 0x33]
        let pipeline = MediaPipeline(ssrcToStripe: Dictionary(uniqueKeysWithValues: ssrcs.enumerated().map { ($1, $0) }),
                                     canvas: (64, 64), ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let sent = Recorder<UInt16>()
        var seq: [UInt16] = [100, 200, 300, 400]
        let state = pipeline.queue.sync {
            pipeline.onReferenceAcknowledgment = { sent.add($0) }
            pipeline.setReferenceAcknowledgments(active: true)
            var donl: UInt16 = 0
            for (n, ts) in [UInt32(1000), 1400, 1800].enumerated() {
                for stripe in 0..<4 {
                    let nal = SyntheticHEVCRTP.vcl(type: n == 0 && stripe == 0 ? 20 : 1)
                    pipeline.ingest(SyntheticHEVCRTP.rtp(ssrc: ssrcs[stripe], seq: seq[stripe], ts: ts, marker: true,
                                                         payload: SyntheticHEVCRTP.single(nal, donl: donl)), arrival: UInt64(n) * 16 * ms)
                    seq[stripe] &+= 1; donl &+= 1
                }
            }
            pipeline.poll(now: 100 * ms)
            return pipeline.referenceAcknowledgmentState
        }
        #expect(pipeline.counters.snapshot.accessUnits == 12)
        #expect(sent.all.isEmpty && state.counters.noted == 0)
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS     // HEVC444Fixture exists only here
    /// On hardware the real hand-over point is reached: every stripe-0 unit
    /// handed to the decoder is confirmed once, by the packet that completed it,
    /// with its own DONL; after a reset, pictures without a new random-access
    /// point are never confirmed. Skipped without a hardware decoder (simulators).
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "needs a hardware HEVC decoder (physical device)"))
    func hardwareDecodedStripeZeroUnitsAreConfirmedOneByOne() throws {
        let aus = HEVC444Fixture.accessUnits
        let ssrc: UInt32 = 0x444F
        for active in [true, false] {
            let pipeline = MediaPipeline(ssrcToStripe: [ssrc: 0], canvas: nil, ruleOverride: nil,
                                         mailbox: DesktopUpdateMailbox(recordsUpdates: true), evidence: EvidenceLog())
            let sent = Recorder<UInt16>()
            pipeline.queue.sync {
                pipeline.onReferenceAcknowledgment = { sent.add($0) }
                pipeline.setReferenceAcknowledgments(active: active)
            }
            func feed(_ au: [Data], seq: UInt16, donl: UInt16, ts: UInt32) {
                let packet = SyntheticHEVCRTP.rtp(ssrc: ssrc, seq: seq, ts: ts, marker: true,
                                                  payload: SyntheticHEVCRTP.aggregation(au.map { [UInt8]($0) }, donl: donl))
                pipeline.queue.sync { pipeline.ingest(packet, arrival: DispatchTime.now().uptimeNanoseconds) }
            }
            var perPacket: [Int] = []
            for (i, au) in aus.enumerated() {
                feed(au, seq: UInt16(i + 1), donl: UInt16(i), ts: UInt32(1000 + i * 400))
                perPacket.append(sent.all.count)
            }
            pipeline.queue.sync { pipeline.resetStream() }
            let beforeReset = sent.all.count
            for (i, au) in aus.enumerated().dropFirst() {                    // P pictures only: no random access
                feed(au, seq: UInt16(100 + i), donl: UInt16(100 + i), ts: UInt32(90_000 + i * 400))
            }
            pipeline.queue.sync { pipeline.poll(now: DispatchTime.now().uptimeNanoseconds); pipeline.resetStream() }
            if active {
                #expect(Array(sent.all.prefix(aus.count)) == (0..<aus.count).map { UInt16($0) })
                #expect(perPacket == Array(1...aus.count))
                #expect(sent.all.count == beforeReset)
            } else {
                #expect(sent.all.isEmpty)
            }
        }
    }
    #endif
}

/// Transport level: SRTCP on the video leg, activation and the offer lifecycle.
@Suite("LTRP acknowledgments on the video leg", .serialized)
struct ReferenceAcknowledgmentTransportTests {
    private func defaults(_ value: String?) -> UserDefaults {
        let d = UserDefaults(suiteName: "vicinia.tests.ltrp.\(UUID().uuidString)")!
        if let value { d.set(value, forKey: "ltrp-ack") }
        return d
    }

    private func run(control: String?, answer: LTRPNegotiation, codec: VideoCodec = .hevc)
        throws -> (sent: [([UInt8], Data)], offer: MediaOffer, transport: MediaTransport, active: Bool) {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let sent = Recorder<Packet>()
        let active = try pipeline.queue.sync {
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onReferenceAcknowledgmentSent = { sent.add(Packet(plain: $0, protected: $1)) }
            transport.referenceAcknowledgments(answer: answer, codec: codec, offerID: 1, defaults: defaults(control))
            pipeline.noteHandedToDecoding(stripe: 0, donl: 0xBEEF)
            pipeline.poll(now: 1_000_000)
            return pipeline.referenceAcknowledgmentState.active
        }
        return (sent.all.map { ($0.plain, $0.protected) }, offer, transport, active)
    }
    private struct Packet: Sendable { let plain: [UInt8]; let protected: Data }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @Test func acknowledgmentIsSRTCPProtectedOnTheVideoLegFromTheVideoSSRC() throws {
        let r = try run(control: "on", answer: .enabled)
        #expect(r.active)
        let packet = try #require(r.sent.first)
        #expect(r.sent.count == 1)
        let s = r.offer.videoSSRC
        #expect(packet.0 == [0x80, 0xCC, 0x00, 0x03, UInt8(s >> 24), UInt8(s >> 16 & 0xFF), UInt8(s >> 8 & 0xFF), UInt8(s & 0xFF),
                             0, 0, 0, 5, 0, 0, 0xBE, 0xEF])
        let host = try SRTPSession(keySalt: r.offer.keys.videoToHost, inbound: true)      // the host's view of our video leg
        #expect([UInt8](try host.unprotectRTCP(packet.1)) == packet.0)
        #expect(r.transport.counters.ltrpAcksSent == 1 && r.transport.counters.ltrpAckFailures == 0)
    }

    @Test func nothingIsSentUnlessEveryConditionHolds() throws {
        for (control, answer, codec) in [("off", LTRPNegotiation.enabled, VideoCodec.hevc), (nil, .enabled, .hevc),
                                         ("on", .disabled, .hevc), ("on", .absent("x"), .hevc), ("on", .unparseable("x"), .hevc),
                                         ("on", .enabled, .other)] {
            let r = try run(control: control, answer: answer, codec: codec)
            #expect(!r.active && r.sent.isEmpty, "\(String(describing: control)) \(answer) \(codec)")
        }
    }
    #else
    @Test func standardBuildAutomaticallySendsSRTCPAcknowledgmentsForAnEnabledHEVCAnswer() throws {
        let answer = MediaOffer.videoLTRP(inAnswer: try SyntheticAnswer.adjacent(ltrp: 1))
        let r = try run(control: nil, answer: answer)
        #expect(r.active)
        #expect(r.sent.count == 1)
        let packet = try #require(r.sent.first)
        let host = try SRTPSession(keySalt: r.offer.keys.videoToHost, inbound: true)
        #expect([UInt8](try host.unprotectRTCP(packet.1))
                == RTCPBuild.referenceAcknowledgment(sender: r.offer.videoSSRC, donl: 0xBEEF))
    }

    @Test func standardBuildRequiresNegotiationAndIgnoresTheDiagnosticSwitch() throws {
        let enabled = try run(control: "off", answer: .enabled)
        #expect(enabled.active && enabled.sent.count == 1)
        for (answer, codec) in [(LTRPNegotiation.disabled, VideoCodec.hevc), (.absent("x"), .hevc),
                                (.unparseable("x"), .hevc), (.enabled, .other)] {
            let r = try run(control: "on", answer: answer, codec: codec)
            #expect(!r.active && r.sent.isEmpty, "\(answer) \(codec)")
        }
    }
    #endif

    /// A new offer starts without acknowledgments; a decision for an older offer is ignored; suspend and stop end them.
    @Test func everyOfferStartsInactiveAndStopEndsAcknowledgments() throws {
        let r = try run(control: "on", answer: .enabled)
        let offer2 = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let sent = Recorder<Int>()
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let states = try pipeline.queue.sync {
            var states: [Bool] = []
            try transport.configure(keys: r.offer.keys, videoSSRC: r.offer.videoSSRC, audioSSRC: r.offer.audioSSRC, offerID: 1)
            transport.onReferenceAcknowledgmentSent = { _, _ in sent.add(1) }
            transport.referenceAcknowledgments(answer: .enabled, codec: .hevc, offerID: 1, defaults: defaults("on"))
            states.append(pipeline.referenceAcknowledgmentState.active)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 1)
            transport.suspend()
            states.append(pipeline.referenceAcknowledgmentState.active)
            pipeline.poll(now: 500_000)
            try transport.configure(keys: offer2.keys, videoSSRC: offer2.videoSSRC, audioSSRC: offer2.audioSSRC, offerID: 2)
            states.append(pipeline.referenceAcknowledgmentState.active)
            transport.referenceAcknowledgments(answer: .enabled, codec: .hevc, offerID: 1, defaults: defaults("on"))   // stale
            states.append(pipeline.referenceAcknowledgmentState.active)
            transport.referenceAcknowledgments(answer: .enabled, codec: .hevc, offerID: 2, defaults: defaults("on"))
            states.append(pipeline.referenceAcknowledgmentState.active)
            pipeline.poll(now: 1_000_000)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 2)
            transport.stop()
            states.append(pipeline.referenceAcknowledgmentState.active)
            pipeline.noteHandedToDecoding(stripe: 0, donl: 1)
            pipeline.poll(now: 1_000_000)
            return states
        }
        #expect(states == [true, false, false, false, true, false])
        #expect(sent.all.isEmpty)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        #expect(evidence.value("ltrp.active") == "true")                      // the decision taken for offer 2's answer
        #expect(evidence.value("ltrp.answer.offer2") == "ENABLED")
        #endif
    }
}
