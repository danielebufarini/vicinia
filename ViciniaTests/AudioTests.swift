// Vicinia tests — Mac audio: offer field, reorder and loss handling, playout
// pacing, AAC-ELD decoding, the transport hand-over and the pipeline's
// lifecycle through an offline engine graph and a simulated audio session.
// SPDX-License-Identifier: MIT

import AVFAudio
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import Vicinia

/// Records AVAudioSession use without touching the device's audio.
final class FakeAudioSession: AudioSessionControlling {
    let ownership = AudioSessionOwnership()
    let activations = Atomic<Int>(0), deactivations = Atomic<Int>(0)
    let refuses = Atomic<Bool>(false)
    private let routeState = Mutex<(latency: TimeInterval, routeIDs: [String])>((0.010, ["Fake"]))
    private let ioDuration: TimeInterval
    private let onReadIODuration: @Sendable () -> Void
    private let onActivate: @Sendable () throws -> Void

    init(ioBufferDuration: TimeInterval = 0.005, outputLatency: TimeInterval = 0.010,
         outputRouteIDs: [String] = ["Fake"], onActivate: @escaping @Sendable () throws -> Void = {},
         onReadIODuration: @escaping @Sendable () -> Void = {}) {
        ioDuration = ioBufferDuration
        routeState.withLock { $0 = (outputLatency, outputRouteIDs) }
        self.onReadIODuration = onReadIODuration
        self.onActivate = onActivate
    }
    struct Refused: Error {}
    func activate() throws {
        try onActivate()
        if refuses.load(ordering: .relaxed) { throw Refused() }
        activations.add(1, ordering: .relaxed)
    }
    func deactivate() { deactivations.add(1, ordering: .relaxed) }
    func setRoute(latency: TimeInterval? = nil, routeIDs: [String]? = nil) {
        routeState.withLock { state in
            if let latency { state.latency = latency }
            if let routeIDs { state.routeIDs = routeIDs }
        }
    }
    var ioBufferDuration: TimeInterval {
        onReadIODuration()
        return ioDuration
    }
    var outputLatency: TimeInterval { routeState.withLock { $0.latency } }
    var outputRouteIDs: [String] { routeState.withLock { $0.routeIDs } }
}

private let ms: UInt64 = 1_000_000

private final class PausedAudioWork: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let expired = Atomic(false)
    var timedOut: Bool { expired.load(ordering: .acquiring) }

    func pause() {
        entered.signal()
        if release.wait(timeout: .now() + .seconds(5)) != .success {
            expired.store(true, ordering: .releasing)
        }
    }

    func reached() -> Bool { entered.wait(timeout: .now() + .seconds(3)) == .success }
    func resume() { release.signal() }
}

private func packet(_ sequence: UInt16, ssrc: UInt32 = 0xA0D1_0001, generation: UInt64 = 1, arrival: UInt64 = 0,
                    payload: [UInt8] = [0, 0, 0, 0], timestamp: UInt32? = nil) -> AudioPacket {
    AudioPacket(sequence: sequence, timestamp: timestamp ?? UInt32(sequence) &* 480, ssrc: ssrc, payload: Data(payload),
                arrival: arrival, mediaGeneration: generation)
}

private func nonSilentFrames(_ buffer: AVAudioPCMBuffer) -> Int {
    guard let planes = buffer.floatChannelData else { return -1 }
    return (0..<Int(buffer.frameLength)).count { abs(planes[0][$0]) > 0.001 || abs(planes[1][$0]) > 0.001 }
}

private func played(_ events: [AudioReorderBuffer.Event]) -> [UInt64] {
    events.compactMap { if case .play(_, _, let s, _) = $0 { s & 0xFFFF } else { nil } }
}

/// Mean power of `x` at `f` Hz (Goertzel), normalized by length.
private func power(_ x: ArraySlice<Float>, _ f: Double) -> Double {
    let c = 2 * cos(2 * Double.pi * f / HPSSAudio.sampleRate)
    var s1 = 0.0, s2 = 0.0
    for v in x { let s = Double(v) + c * s1 - s2; s2 = s1; s1 = s }
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
}

@Suite("Audio offer")
struct AudioOfferTests {
    @Test func suppressedAudioBlobIsUnchangedAndRequestedOnlyChangesFieldFour() {
        let suppressed = MediaOffer.mediaBlob(video: false, sessionID: 0x5566_7788, clientName: "Vicinia-Test 0.1.0",
                                              timestampNanos: 1_700_000_000_000_000_000)
        #expect(suppressed == OracleVectors.mediaBlobAudio)
        let requested = MediaOffer.mediaBlob(video: false, sessionID: 0x5566_7788, clientName: "Vicinia-Test 0.1.0",
                                             timestampNanos: 1_700_000_000_000_000_000, audio: .requested)
        // Field 3 (audio description) is the only difference: length 0x11 → 0x12 and f4 1000 → 24191.
        let oldDescription: [UInt8] = [0x1A, 0x11, 0x08, 0x88, 0xEF, 0x99, 0xAB, 0x05, 0x10, 0x00, 0x18, 0x00,
                                       0x20, 0xE8, 0x07, 0x28, 0x00, 0x30, 0x00]
        let newDescription: [UInt8] = [0x1A, 0x12, 0x08, 0x88, 0xEF, 0x99, 0xAB, 0x05, 0x10, 0x00, 0x18, 0x00,
                                       0x20, 0xFF, 0xBC, 0x01, 0x28, 0x00, 0x30, 0x00]
        #expect(Array(suppressed[4..<23]) == oldDescription)
        #expect(Array(requested[4..<24]) == newDescription)
        #expect(Array(requested[24...]) == Array(suppressed[23...]))
        #expect(Array(requested[..<4]) == Array(suppressed[..<4]))
        #expect(AudioRequest.requested.preferredBitRate == 24_191 && AudioRequest.suppressed.preferredBitRate == 1_000)
    }

    @Test func offerCarriesTheRequestedAudioDescription() throws {
        let offer = try MediaOffer.make(clientName: "Vicinia 0.1", hardwareModel: "iPhone18,4", osBuild: "24B156",
                                        audio: .requested)
        let m = offer.message
        let audioLength = Int(m[10]) << 8 | Int(m[11])
        let plist = Data(m[0x80 ..< 0x80 + audioLength])
        let dict = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        #expect(dict["avcMediaStreamNegotiatorMode"] as? Int == 8)
        let blob = try zlibDecompress([UInt8](try #require(dict["avcMediaStreamNegotiatorMediaBlob"] as? Data)), limit: 1 << 16)
        var top = ProtoIterator(blob)
        var description: [UInt8]?
        while description == nil, let (field, wire, _, bytes) = top.next() { if field == 3, wire == 2 { description = bytes } }
        var fields: [UInt64: UInt64] = [:]
        var it = ProtoIterator(try #require(description))
        while let (field, wire, value, _) = it.next() { if wire == 0 { fields[field] = value } }
        #expect(fields[1] == UInt64(offer.audioSSRC))                          // our audio SSRC
        #expect(fields[4] == 24_191)
    }
}

@Suite("Audio reorder buffer")
struct AudioReorderTests {
    @Test func aForwardGapAndAForwardDiscontinuityAreDistinct() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(1), reorderWait: 20 * ms)
        #expect(b.insert(packet(1501, arrival: ms), reorderWait: 20 * ms).isEmpty)
        #expect(b.expire(now: 21 * ms, reorderWait: 20 * ms).first == .lost(1499))
        let jump = b.insert(packet(3002, arrival: 22 * ms), reorderWait: 20 * ms)
        #expect(jump.first == .restart(.sequenceJump) && played(jump) == [3002])
    }

    @Test func replayWindowLatePacketDoesNotRestartPlayout() {
        var b = AudioReorderBuffer()
        for s in UInt16(1)...1005 { _ = b.insert(packet(s), reorderWait: .max) }
        #expect(b.insert(packet(2), reorderWait: .max).isEmpty)
        #expect(played(b.insert(packet(1006), reorderWait: .max)) == [1006])
        #expect(b.counters.late == 1 && b.counters.restarts == 0)
    }

    @Test func expiryBeforeArrivalDoesNotDeclareLoss() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(1), reorderWait: 20 * ms)
        _ = b.insert(packet(3, arrival: 30 * ms), reorderWait: 20 * ms)
        #expect(b.expire(now: 29 * ms, reorderWait: 20 * ms).isEmpty)
        #expect(b.counters.lost == 0)
        #expect(played(b.expire(now: 50 * ms, reorderWait: 20 * ms)) == [3])
    }

    @Test func olderOfferCannotReplaceTheCurrentStream() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(1, generation: 2), reorderWait: .max)
        #expect(b.insert(packet(2, generation: 1), reorderWait: .max).isEmpty)
        #expect(b.counters.late == 1 && b.counters.restarts == 0)
        #expect(played(b.insert(packet(2, generation: 2), reorderWait: .max)) == [2])
    }

    @Test func inOrderPacketsPlayImmediately() {
        var b = AudioReorderBuffer()
        var out: [UInt64] = []
        for s in UInt16(10)...15 { out += played(b.insert(packet(s), reorderWait: 20 * ms)) }
        #expect(out == Array(10...15))
        #expect(b.counters.played == 6 && b.counters.lost == 0 && b.heldCount == 0)
    }

    @Test func reorderedPacketWaitsAndDuplicatesAndLatePacketsAreDropped() {
        var b = AudioReorderBuffer()
        #expect(played(b.insert(packet(1, arrival: 0), reorderWait: 20 * ms)) == [1])
        #expect(played(b.insert(packet(3, arrival: 10 * ms), reorderWait: 20 * ms)).isEmpty)   // 2 is missing
        #expect(played(b.insert(packet(2, arrival: 12 * ms), reorderWait: 20 * ms)) == [2, 3])
        #expect(b.counters.reordered == 1)
        #expect(b.insert(packet(3, arrival: 13 * ms), reorderWait: 20 * ms).isEmpty)
        #expect(b.insert(packet(1, arrival: 14 * ms), reorderWait: 20 * ms).isEmpty)
        #expect(b.counters.late == 2)                                       // already played
        #expect(played(b.insert(packet(5, arrival: 20 * ms), reorderWait: 20 * ms)).isEmpty)
        #expect(b.insert(packet(5, arrival: 21 * ms), reorderWait: 20 * ms).isEmpty)
        #expect(b.counters.duplicates == 1)
    }

    @Test func missingPacketIsLostOnceALaterOneHasWaited() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(100, arrival: 0), reorderWait: 20 * ms)
        #expect(played(b.insert(packet(102, arrival: 20 * ms), reorderWait: 20 * ms)).isEmpty)
        #expect(b.expire(now: 39 * ms, reorderWait: 20 * ms).isEmpty)
        let events = b.expire(now: 40 * ms, reorderWait: 20 * ms)
        #expect(events.first == .lost(1) && played(events) == [102])
        #expect(b.insert(packet(101, arrival: 41 * ms), reorderWait: 20 * ms).isEmpty)   // too late now
        #expect(b.counters.lost == 1 && b.counters.late == 1)
    }

    @Test func holdingBeyondCapacityGivesUpTheGap() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(0), reorderWait: .max)
        var events: [AudioReorderBuffer.Event] = []
        for s in UInt16(2)...UInt16(2 + AudioReorderBuffer.capacity) { events += b.insert(packet(s), reorderWait: .max) }
        #expect(events.contains(.lost(1)))
        #expect(played(events) == Array(2...UInt64(2 + AudioReorderBuffer.capacity)))
        #expect(b.heldCount == 0)
    }

    @Test func sequenceWrapIsContinuous() {
        var b = AudioReorderBuffer()
        var out: [UInt64] = []
        for s: UInt16 in [65_533, 65_534, 65_535, 0, 1] { out += played(b.insert(packet(s), reorderWait: 20 * ms)) }
        #expect(out == [65_533, 65_534, 65_535, 0, 1])
        // Reordered across the wrap.
        #expect(played(b.insert(packet(3), reorderWait: 20 * ms)).isEmpty)
        #expect(played(b.insert(packet(2), reorderWait: 20 * ms)) == [2, 3])
        #expect(b.counters.lost == 0 && b.counters.late == 0 && b.counters.restarts == 0)
    }

    @Test func newStreamIdentityRestartsWithoutPlayingOlderPackets() {
        var b = AudioReorderBuffer()
        _ = b.insert(packet(10), reorderWait: .max)
        _ = b.insert(packet(12), reorderWait: .max)                         // held: 11 missing
        let ssrc = b.insert(packet(500, ssrc: 0xBEEF), reorderWait: .max)
        #expect(ssrc.first == .restart(.ssrc) && played(ssrc) == [500])     // the held 12 is discarded, not played
        let generation = b.insert(packet(7, ssrc: 0xBEEF, generation: 2), reorderWait: .max)
        #expect(generation.first == .restart(.mediaGeneration) && played(generation) == [7])
        let jump = b.insert(packet(7 &+ 5000, ssrc: 0xBEEF, generation: 2), reorderWait: .max)
        #expect(jump.first == .restart(.sequenceJump) && played(jump) == [5007])
        #expect(b.counters.restarts == 3 && b.heldCount == 0 && b.counters.played == 4)
    }
}

@Suite("Audio playout control")
struct PlayoutControlTests {
    @Test func audioVideoErrorSteersPacingAtConstantOccupancy() {
        var late = PlayoutControl(), early = PlayoutControl(), fallback = PlayoutControl()
        let level = late.targetFrames
        #expect(late.decide(level: level, avErrorFrames: 1920) == .play(adjust: -4))
        #expect(early.decide(level: level, avErrorFrames: -1920) == .play(adjust: 4))
        #expect(fallback.decide(level: level) == .play(adjust: 0))
    }

    @Test func targetFollowsTheRouteAndMeasuredJitterWithinBounds() {
        var p = PlayoutControl()
        p.setRoute(ioBufferDuration: 0.005)
        #expect(p.minimumFrames == 960 && p.targetFrames == 960)            // one packet + two 5 ms quanta
        p.setRoute(ioBufferDuration: 0.02)
        #expect(p.minimumFrames == 480 + 2 * 960)
        p.setRoute(ioBufferDuration: 0.005)
        var t: UInt64 = 0
        for s in UInt64(0)..<200 {                                          // ±4 ms alternating arrival jitter
            t = s * 10 * ms + (s % 2 == 0 ? 0 : 8 * ms)
            p.noteArrival(sequence: s, arrival: t)
        }
        #expect(p.jitterNanos > 6e6 && p.jitterNanos < 9e6)
        #expect(p.targetFrames > 960 && p.targetFrames <= PlayoutControl.maximumTargetFrames)
        for s in UInt64(200)..<400 { p.noteArrival(sequence: s, arrival: s * 10 * ms + 800 * ms * (s % 2)) }  // absurd: bounded
        #expect(p.targetFrames == PlayoutControl.maximumTargetFrames)
    }

    @Test func pausesAndSequenceGapsAreNotJitter() {
        var p = PlayoutControl()
        p.setRoute(ioBufferDuration: 0.005)
        p.noteArrival(sequence: 0, arrival: 0)
        p.noteArrival(sequence: 1, arrival: 10 * ms)
        p.noteArrival(sequence: 6, arrival: 60 * ms)                        // four lost packets, on time
        #expect(p.jitterNanos == 0)
        p.noteArrival(sequence: 7, arrival: 5_000 * ms)                     // a pause, not jitter
        #expect(p.jitterNanos == 0 && p.targetFrames == 960)
    }

    @Test func levelIsKeptNearTheTargetAndBurstsAreTrimmed() {
        var p = PlayoutControl()
        p.setRoute(ioBufferDuration: 0.005)
        #expect(p.decide(level: 0) == .prime)
        for _ in 0..<64 { _ = p.decide(level: 960) }
        #expect(p.decide(level: 960) == .play(adjust: 0))
        var shortened = 0
        for _ in 0..<64 { if p.decide(level: 960 + 600) == .play(adjust: -PlayoutControl.correctionFrames) { shortened += 1 } }
        #expect(shortened > 0)                                              // drift above the target: shorter blocks
        for _ in 0..<128 { _ = p.decide(level: 960) }
        var lengthened = 0
        for _ in 0..<64 { if p.decide(level: 960 - 600) == .play(adjust: PlayoutControl.correctionFrames) { lengthened += 1 } }
        #expect(lengthened > 0)
        #expect(p.decide(level: 960 + 4 * PlayoutControl.hysteresisFrames + 480 + 1) == .drop)
        #expect(p.counters.primes == 1 && p.counters.dropped == 1)
    }
}

@Suite("Audio block resampler")
struct BlockResamplerTests {
    @Test func resamplesToTheRequestedLengthKeepingBothEnds() throws {
        let format = try #require(HPSSAudio.pcmFormat())
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        block.frameLength = 480
        for c in 0..<2 { for i in 0..<480 { block.floatChannelData![c][i] = Float(i) * (c == 0 ? 1 : -1) } }
        for count in [476, 484] {
            let out = try #require(BlockResampler.resample(block, to: count))
            #expect(out.frameLength == AVAudioFrameCount(count))
            for c in 0..<2 {
                let d = out.floatChannelData![c], sign: Float = c == 0 ? 1 : -1
                #expect(d[0] == 0 && abs(d[count - 1] - 479 * sign) < 1e-3)
                #expect(abs(d[count / 2] - sign * Float(count / 2) * 479 / Float(count - 1)) < 1e-3)   // a ramp stays a ramp
            }
        }
    }
}

@Suite("AAC-ELD decoder")
struct AACELDDecoderTests {
    private func decodeAll(_ decoder: AACELDDecoder) throws -> (frames: [Int], left: [Float], right: [Float]) {
        var frames: [Int] = [], left: [Float] = [], right: [Float] = []
        for unit in AudioFixture.accessUnits {
            let out = try decoder.decode(Data(unit))
            frames.append(Int(out.frameLength))
            left += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            right += UnsafeBufferPointer(start: out.floatChannelData![1], count: Int(out.frameLength))
        }
        return (frames, left, right)
    }

    @Test func decodesRealAccessUnitsToTenMillisecondStereoBlocks() throws {
        let decoder = try AACELDDecoder(cookie: AudioFixture.cookie)
        #expect(decoder.outputFormat.sampleRate == 48_000 && decoder.outputFormat.channelCount == 2)
        let (frames, left, right) = try decodeAll(decoder)
        #expect(frames.dropFirst().allSatisfy { $0 == 480 })                // 480 frames = 10 ms per access unit
        #expect(frames.first.map { $0 <= 480 } == true)                     // decoder delay on the first one
        let l = left[2400 ..< 6240], r = right[2400 ..< 6240]
        #expect(power(l, 1000) > 100 * power(l, 440) && power(l, 1000) > 1e-3)   // channel order kept
        #expect(power(r, 440) > 100 * power(r, 1000) && power(r, 440) > 1e-3)
    }

    @Test func theHostConfigurationIsAcceptedAndKeepsTheCoreBand() throws {
        // The host and fixture use different SBR headers. Compare the core band.
        let decoder = try AACELDDecoder()
        let (frames, left, right) = try decodeAll(decoder)
        #expect(frames.dropFirst().allSatisfy { $0 == 480 })
        let l = left[2400 ..< 6240], r = right[2400 ..< 6240]
        #expect(power(l, 1000) > 100 * power(l, 440) && power(r, 440) > 100 * power(r, 1000))
    }

    @Test func invalidAccessUnitsAreRejectedBeforeDecodingAndDecodingRecovers() throws {
        let decoder = try AACELDDecoder(cookie: AudioFixture.cookie)
        #expect(throws: AACELDDecoder.Failure.invalidAccessUnit(0)) { _ = try decoder.decode(Data()) }
        let oversize = HPSSAudio.maxAccessUnitBytes + 1
        #expect(throws: AACELDDecoder.Failure.invalidAccessUnit(oversize)) {
            _ = try decoder.decode(Data(repeating: 0x5A, count: oversize))
        }
        for garbage in [[UInt8](repeating: 0xA5, count: 200), [UInt8](repeating: 0xFF, count: 300)] {
            #expect(throws: (any Error).self) { _ = try decoder.decode(Data(garbage)) }   // an error or no frames: never audio
        }
        let (frames, left, _) = try decodeAll(decoder)                      // the same decoder keeps working
        #expect(frames.suffix(10).allSatisfy { $0 == 480 })
        #expect(power(left[4800 ..< 7680], 1000) > 1e-3)
    }

    @Test func silenceAccessUnitsDecodeToSilence() throws {
        let decoder = try AACELDDecoder()
        var peak: Float = 0, frames = 0
        for _ in 0..<4 {
            let out = try decoder.decode(Data([0, 0, 0, 0]))
            frames += Int(out.frameLength)
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
        }
        #expect(frames >= 3 * 480 && peak == 0)
    }

    /// AudioToolbox configures this decoder from the stream description: the
    /// output does not depend on the cookie, so the 480-frame stream
    /// description is the contract (see HPSSAudio.magicCookie).
    @Test func decodedOutputDoesNotDependOnTheCookie() throws {
        let own = try decodeAll(try AACELDDecoder(cookie: AudioFixture.cookie))
        let host = try decodeAll(try AACELDDecoder())
        let none = try decodeAll(try AACELDDecoder(cookie: []))
        #expect(own.frames == host.frames && own.left == host.left && own.right == host.right)
        #expect(own.left == none.left && own.right == none.right)
        #expect(AudioPipeline.canDecode)
    }
}

@Suite("Audio transport hand-over", .serialized)
struct AudioTransportTests {
    private func rtp(_ seq: UInt16, pt: UInt8, ssrc: UInt32, timestamp: UInt32? = nil,
                     payload: [UInt8] = [0, 0, 0, 0]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x80); w.u8(pt); w.u16(seq); w.u32(timestamp ?? UInt32(seq) * 480); w.u32(ssrc)
        w.append(payload)
        return w.bytes
    }

    func sr(_ source: UInt32, _ seconds: UInt32, _ rtp: UInt32) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0x80); w.u8(200); w.u16(6); w.u32(source); w.u32(4_004_090_000 + seconds)
        w.u32(0); w.u32(rtp); w.u32(10); w.u32(400)
        return w.bytes
    }

    @Test func decoderRebuildsRetireOnlyLocalPresentationTiming() throws {
        let evidence = EvidenceLog.disabled
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline)
        let clock = audio.avClock
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence, avClock: clock)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 1, audio: audio)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        let hostAudio = try SRTPSession(keySalt: offer.keys.audioFromHost, inbound: false)
        let hostVideo = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
        defer { pipeline.queue.sync { transport.stop() }; audio.terminate() }
        let a: UInt32 = 480_000, v: UInt32 = 240_000
        let origin: UInt64 = 20_000 * ms
        // Length-prefixed VPS/SPS/PPS and IDR from three 64×64 black HEVC
        // frames. The SPS timing changes each time, without an offer or SSRC change.
        let frames = [
            "ABhAAQwB//8BYAAAAwCQAAADAAADAB6VmAkAKEIBAQFgAAADAJAAAAMAAAMAHqAggQWWVmkkyvAWgIAAAAMAgAAACgQAB0QBwXK0IkAADigBrx2A9wFb//JO/szw",
            "ABhAAQwB//8BYAAAAwCQAAADAAADAB6VmAkAKEIBAQFgAAADAJAAAAMAAAMAHqAggQWWVmkkyvAWgIAAAAMAgAAACoQAB0QBwXK0IkAADigBrx2A9wFb//JO/szw",
            "ABhAAQwB//8BYAAAAwCQAAADAAADAB6VmAkAKEIBAQFgAAADAJAAAAMAAAMAHqAggQWWVmkkyvAWgIAAAAMAgAAACwQAB0QBwXK0IkAADigBrx2A9wFb//JO/szw",
        ]
        func submit(_ index: Int, rtpMS: UInt32) throws {
            let nals = try #require(Data(base64Encoded: frames[index]))
            var w = ByteWriter()
            w.u8(0x80); w.u8(0x80 | 100); w.u16(UInt16(index + 1)); w.u32(v + rtpMS * 24); w.u32(8)
            w.u8(48 << 1); w.u8(1); w.u16(UInt16(index)); w.append(nals)
            try pipeline.queue.sync {
                transport.ingestVideo(try hostVideo.protectRTP(w.bytes), now: origin + UInt64(rtpMS) * ms)
            }
        }
        func present(_ generation: UInt64, _ rtpMS: UInt32, delay: UInt64) {
            clock.videoPresented(offer: 1, generation: generation, timestamp: v + rtpMS * 24,
                                 nanos: origin + (UInt64(rtpMS) + delay) * ms)
        }
        func error(_ rtpMS: UInt32, lead: UInt64 = 160, decision: UInt64) -> Double? {
            clock.audioErrorFrames(offer: 1, ssrc: 7, timestamp: a + rtpMS * 48, now: origin + decision * ms,
                                   renderHostNanos: origin + (UInt64(rtpMS) + lead - 30) * ms,
                                   playerSample: 0, startSample: 960, outputLatency: 0.010)
        }
        try pipeline.queue.sync {
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.canvasKnown(width: 64, height: 64, offerID: 1)
            transport.ingestAudio(try hostAudio.protectRTP(rtp(1, pt: 101, ssrc: 7, timestamp: a)), now: origin)
        }
        try submit(0, rtpMS: 0)
        #expect(pipeline.isCurrent(generation: 5))
        try pipeline.queue.sync {
            for second: UInt32 in 0...1 {
                let now = origin + UInt64(second) * 1000 * ms
                transport.ingestAudio(try hostAudio.protectRTCP(sr(7, second, a + second * 48_000)), now: now)
                transport.ingestVideo(try hostVideo.protectRTCP(sr(8, second, v + second * 24_000)), now: now)
            }
            #expect(transport.counters.srtcpFailures == 0 && transport.counters.hostSenderReports == 4)
        }
        present(5, 1300, delay: 80)
        #expect(abs(try #require(error(1300, decision: 1400)) - 3840) < 0.001)

        try submit(1, rtpMS: 1400)
        #expect(!pipeline.isCurrent(generation: 5) && pipeline.isCurrent(generation: 6))
        var fallback = PlayoutControl()
        #expect(fallback.decide(level: fallback.targetFrames, avErrorFrames: error(1400, decision: 1490))
                == .play(adjust: 0))
        present(5, 1450, delay: 80)  // passed the renderer gate before retirement
        #expect(error(1450, decision: 1540) == nil)
        present(6, 1550, delay: 200)
        let current = try #require(error(1600, decision: 1755))
        #expect(abs(current - (-1920)) < 0.001, "error ms: \(current / 48)")
        var pacing = PlayoutControl()
        #expect(pacing.decide(level: pacing.targetFrames + 240, avErrorFrames: current) == .play(adjust: 4))

        try submit(2, rtpMS: 1800)
        #expect(pipeline.isCurrent(generation: 7) && pipeline.counters.snapshot.generations == 3)
        present(6, 1780, delay: 200)
        #expect(error(1810, decision: 1950) == nil)
        present(7, 1850, delay: 70)
        present(5, 1860, delay: 100) // delivered later, with a newer host timestamp
        #expect(abs(try #require(error(1900, lead: 70, decision: 1965))) < 0.001)
    }

    @Test func authenticatedSenderReportsFeedTheProductionClocks() throws {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 1, audio: audio)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        defer { pipeline.queue.sync { transport.stop() }; audio.terminate() }
        let hostAudio = try SRTPSession(keySalt: offer.keys.audioFromHost, inbound: false)
        let hostVideo = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
        let wrong = try SRTPSession(keySalt: offer.keys.audioToHost, inbound: false)
        let a: UInt32 = 0x1000_0000, v: UInt32 = 0x10_0000
        let now = DispatchTime.now().uptimeNanoseconds
        try pipeline.queue.sync {
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.ingestAudio(try hostAudio.protectRTP(rtp(1, pt: 101, ssrc: 7, timestamp: a)), now: now)
            transport.ingestVideo(try hostVideo.protectRTP(rtp(1, pt: 100, ssrc: 8, timestamp: v)), now: now)
            transport.ingestAudio(try hostAudio.protectRTCP(sr(7, 0, a)), now: now)
            transport.ingestVideo(try hostVideo.protectRTCP(sr(8, 0, v)), now: now)
            transport.ingestVideo(try hostVideo.protectRTCP(sr(8, 1, v + 24_000)), now: now + 1000 * ms)
            transport.ingestAudio(try wrong.protectRTCP(sr(7, 1, a + 48_000)), now: now + 1000 * ms)
            #expect(transport.counters.srtcpFailures == 1 && transport.counters.hostSenderReports == 3)
        }
        let render = now + 1530 * ms, shown = now + 1560 * ms
        func error() -> Double? {
            audio.avClock.audioErrorFrames(offer: 1, ssrc: 7, timestamp: a + 72_000, now: shown,
                                           renderHostNanos: render, playerSample: 0, startSample: 960, outputLatency: 0.010)
        }
        audio.avClock.videoPresented(offer: 1, generation: 0, timestamp: v + 36_000, nanos: shown)
        #expect(error() == nil)
        try pipeline.queue.sync {
            transport.ingestAudio(try hostAudio.protectRTCP(sr(7, 1, a + 48_000)), now: now + 1000 * ms)
            #expect(transport.counters.hostSenderReports == 4)
        }
        #expect(abs(try #require(error())) < 0.001)
    }

    @Test func suspensionFlushesThePlayerAndOnlyANewerOfferRestartsIt() throws {
        let evidence = EvidenceLog(), session = FakeAudioSession()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let hold = PausedAudioWork(), park = Atomic(false)
        let audio = AudioPipeline(session: session, output: .offline,
                                  decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
            return block
        })
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 1, audio: audio)
        let first = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        let second = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        defer { hold.resume(); pipeline.queue.sync { transport.stop() }; audio.terminate() }
        let now = DispatchTime.now().uptimeNanoseconds + 10_000 * ms // only the explicit test tick can expire the gap
        let host = try SRTPSession(keySalt: first.keys.audioFromHost, inbound: false)
        func ingest(_ seq: UInt16) throws {
            try pipeline.queue.sync {
                let payload = AudioFixture.accessUnits[Int(seq - 1)]
                transport.ingestAudio(try host.protectRTP(rtp(seq, pt: 101, ssrc: 7, payload: payload)),
                                      now: now + UInt64(seq) * 10 * ms)
            }
        }
        audio.authorize(FeatureAuthorization(session: SessionToken(profileID: UUID(), generation: 1), operation: 1))
        audio.sync()
        try pipeline.queue.sync {
            try transport.configure(keys: first.keys, videoSSRC: first.videoSSRC, audioSSRC: first.audioSSRC, offerID: 1)
        }
        for seq: UInt16 in 1...4 { try ingest(seq); audio.sync() }
        try ingest(7)
        audio.sync()
        #expect(audio.snapshot.counters.scheduled == 4) // 7 is waiting for 5 and 6
        let engine = try #require(audio.offlineEngine)
        park.store(true, ordering: .releasing)
        try ingest(5)
        try #require(hold.reached())
        try pipeline.queue.sync {
            transport.suspend()
            try transport.configure(keys: first.keys, videoSSRC: first.videoSSRC, audioSSRC: first.audioSSRC, offerID: 1)
        }
        #expect(!audio.accept(packet(6)))
        #expect(engine.manualRenderingSampleTime == 0)
        let format = try #require(HPSSAudio.pcmFormat())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        #expect(try engine.renderOffline(4096, to: buffer) == .success && buffer.frameLength == 4096)
        #expect(nonSilentFrames(buffer) == 0 && !hold.timedOut)
        hold.resume()
        audio.queue.sync { audio.tick(now: now + 100 * ms) }
        #expect(!audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)
        let silent = try #require(audio.renderOffline(4096))
        #expect(nonSilentFrames(silent) == 0)

        let nextHost = try SRTPSession(keySalt: second.keys.audioFromHost, inbound: false)
        try pipeline.queue.sync {
            try transport.configure(keys: second.keys, videoSSRC: second.videoSSRC, audioSSRC: second.audioSSRC, offerID: 2)
        }
        for seq: UInt16 in 1...4 {
            try pipeline.queue.sync {
                let payload = AudioFixture.accessUnits[Int(seq - 1)]
                transport.ingestAudio(try nextHost.protectRTP(rtp(seq, pt: 101, ssrc: 7, payload: payload)),
                                      now: now + (200 + UInt64(seq) * 10) * ms)
            }
            audio.sync()
        }
        #expect(!audio.accept(packet(4, generation: 1)))
        audio.mediaStopped(offer: 1)
        audio.sync()
        #expect(audio.snapshot.playing && audio.snapshot.counters.scheduled == 8)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
        pipeline.queue.sync { transport.stop() }
        audio.sync()
        #expect(!audio.snapshot.playing && !audio.accept(packet(2, generation: 2)))
    }

    @Test func saturatedAudioDoesNotDelayAuthenticatedVideoOrLiveness() throws {
        let hold = PausedAudioWork()
        let evidence = EvidenceLog(), callbacks = Recorder<MediaLiveness>()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline,
                                  decodeAccessUnit: { decoder, unit in hold.pause(); return try decoder.decode(unit) })
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 1, audio: audio)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        defer { audio.terminate(); hold.resume(); pipeline.queue.sync { transport.stop() } }
        audio.authorize(FeatureAuthorization(session: SessionToken(profileID: UUID(), generation: 1), operation: 1))
        audio.sync()
        let hostAudio = try SRTPSession(keySalt: offer.keys.audioFromHost, inbound: false)
        let hostVideo = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
        let now = DispatchTime.now().uptimeNanoseconds
        try pipeline.queue.sync {
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onLiveness = { callbacks.add($0) }
            transport.checkLiveness(now: now)
            transport.ingestAudio(try hostAudio.protectRTP(rtp(1, pt: 101, ssrc: 7)), now: now)
        }
        try #require(hold.reached())
        try pipeline.queue.sync {
            for seq in UInt16(2)...100 {
                transport.ingestAudio(try hostAudio.protectRTP(rtp(seq, pt: 101, ssrc: 7)), now: now)
            }
            #expect(transport.counters.audioForwarded == 32 && transport.counters.audioDiscarded == 68)
            #expect(audio.ingressReservations.packets == 32)
            transport.checkLiveness(now: now + 1600 * ms)
            transport.ingestVideo(try hostVideo.protectRTP(rtp(1, pt: 100, ssrc: 8)), now: now + 1700 * ms)
            transport.checkLiveness(now: now + 1700 * ms)
            #expect(transport.counters.bufferedBeforeResolution == 1)
            #expect(callbacks.all == [.stalled(seconds: 1.6), .resumed])
        }
        audio.revoke()
        #expect(audio.ingressReservations.packets == 1)
        hold.resume()
        audio.sync()
        #expect(audio.snapshot.counters.packets == 1 && audio.snapshot.counters.scheduled == 0)
        #expect(audio.ingressReservations == (0, 0))
    }

    @Test func onlyAuthenticatedPayloadType101ReachesTheAudioPipeline() throws {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4, audio: audio)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        let host = try SRTPSession(keySalt: offer.keys.audioFromHost, inbound: false)
        let wrongKey = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
        func rtp(_ seq: UInt16, pt: UInt8 = 101) -> [UInt8] {
            var w = ByteWriter(); w.u8(0x80); w.u8(pt); w.u16(seq); w.u32(UInt32(seq) * 480); w.u32(0xA0D1_0001)
            w.append([0, 0, 0, 0]); return w.bytes
        }
        defer { audio.terminate(); pipeline.queue.sync { transport.stop() } }
        audio.authorize(FeatureAuthorization(session: SessionToken(profileID: UUID(), generation: 1), operation: 1_000_001))
        audio.sync()
        #expect(audio.snapshot.accepting)
        try pipeline.queue.sync {
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.ingestAudio(try host.protectRTP(rtp(1)))
            let replay = try host.protectRTP(rtp(2))
            transport.ingestAudio(replay)
            transport.ingestAudio(replay)                                   // replayed: rejected by SRTP
            transport.ingestAudio(try wrongKey.protectRTP(rtp(3)))          // not authentic
            transport.ingestAudio(try host.protectRTP(rtp(4, pt: 100)))     // not the audio payload type
            transport.ingestAudio(Data([0x80, 101] + [UInt8](repeating: 0, count: 30)))
            let c = transport.counters
            #expect(c.audioForwarded == 2 && c.srtpReplays == 1 && c.srtpAuthFailures >= 2 && c.nonAACAudio == 1)
        }
        audio.sync()
        #expect(audio.snapshot.counters.packets == 2)
    }

    @Test func senderReportClocksAreParsedFromCompoundPackets() {
        var w = ByteWriter()
        w.u8(0x81); w.u8(201); w.u16(7); w.u32(1); w.zeros(24)            // an RR with one block first
        w.u8(0x80); w.u8(200); w.u16(6); w.u32(0xA0D1_0001); w.u32(0xE8A0_0000); w.u32(0x8000_0000)
        w.u32(123_456); w.u32(10); w.u32(400)
        let clocks = RTCPBuild.senderReportClocks(Data(w.bytes))
        #expect(clocks.count == 1)
        #expect(clocks.first?.ssrc == 0xA0D1_0001 && clocks.first?.ntpSeconds == 0xE8A0_0000
                && clocks.first?.ntpFraction == 0x8000_0000 && clocks.first?.rtpTimestamp == 123_456)
        #expect(RTCPBuild.senderReports(Data(w.bytes)).map(\.0) == [0xA0D1_0001])   // the LSR parser is unchanged
        #expect(RTCPBuild.senderReportClocks(Data(w.bytes.prefix(40))).isEmpty)       // truncated SR
        var malformed = Array(w.bytes.suffix(28))
        malformed[0] = 0x81                                                      // advertises a missing report block
        #expect(RTCPBuild.senderReportClocks(Data(malformed)).isEmpty)
        malformed[0] = 0x40                                                      // wrong RTCP version
        #expect(RTCPBuild.senderReportClocks(Data(malformed)).isEmpty)
    }
}

/// The production pipeline with the engine rendered offline and a fake session.
@Suite("Audio pipeline lifecycle", .serialized)
struct AudioPipelineTests {
    private enum Cancellation: CaseIterable, Sendable { case revoke, disable, terminate }

    @Test(arguments: Cancellation.allCases)
    private func cancellationDuringAudioSessionActivationCannotOpenOutput(_ cancellation: Cancellation) throws {
        let hold = PausedAudioWork(), session = FakeAudioSession(onActivate: { hold.pause() })
        let (p, _) = make(session: session)
        defer { hold.resume(); p.terminate() }
        p.authorize(Self.authorization())
        try #require(hold.reached())
        switch cancellation {
        case .revoke: p.revoke()
        case .disable: p.setEnabled(false)
        case .terminate: p.terminate()
        }
        #expect(!p.accept(packet(1)))
        hold.resume()
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting && p.snapshot.counters.starts == 0)
        #expect(session.activations.load(ordering: .relaxed) == 1 && session.deactivations.load(ordering: .relaxed) == 1)
    }

    @Test func revocationAtThePCMCommitBoundaryRejectsThePreparedBlock() throws {
        let hold = PausedAudioWork()
        let p = AudioPipeline(session: FakeAudioSession(), output: .offline,
                              beforeCommit: { hold.pause() })
        defer { hold.resume(); p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        #expect(p.accept(packet(1, payload: AudioFixture.accessUnits[3])))
        try #require(hold.reached())
        p.revoke()
        hold.resume()
        p.sync()
        #expect(p.snapshot.counters.decoded == 1 && p.snapshot.counters.scheduled == 0)
        #expect(p.ingressReservations == (0, 0))
    }

    @Test func revocationCannotReturnDuringAnAuthorizedPCMCommit() throws {
        let hold = PausedAudioWork()
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline,
                                  afterCommitValidation: { hold.pause() })
        defer { hold.resume(); audio.terminate() }
        audio.authorize(Self.authorization()); audio.sync()
        let engine = try #require(audio.offlineEngine)
        #expect(audio.accept(packet(1, payload: AudioFixture.accessUnits[0])))
        try #require(hold.reached())
        // Nonblocking check while the worker is past validation and still
        // before scheduleBuffer. This does not depend on task start timing.
        #expect(!audio.pcmCommitIsAvailable)
        let attempting = DispatchSemaphore(value: 0), acknowledged = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            attempting.signal()
            audio.revoke()
            acknowledged.signal()
        }
        try #require(attempting.wait(timeout: .now() + .seconds(3)) == .success)
        let early = acknowledged.wait(timeout: .now() + .milliseconds(100)) == .success
        #expect(!early && !hold.timedOut)
        hold.resume()
        if !early { try #require(acknowledged.wait(timeout: .now() + .seconds(3)) == .success) }
        audio.sync()
        #expect(!audio.snapshot.accepting && !audio.snapshot.running && !engine.isRunning)
        #expect(audio.snapshot.counters.decoded == 1 && audio.snapshot.counters.scheduled == 1)
        #expect(audio.ingressReservations == (0, 0))
    }

    @Test func aDecodedAccessUnitStaysRevokedAcrossSameOfferRegrant() throws {
        let hold = PausedAudioWork(), first = Atomic(true)
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline,
                                  decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if first.exchange(false, ordering: .relaxed) { hold.pause() }
            return block
        })
        defer { hold.resume(); audio.terminate() }
        audio.mediaGenerationChanged(1)
        audio.authorize(Self.authorization()); audio.sync()
        #expect(audio.accept(packet(1, payload: AudioFixture.accessUnits[0])))
        try #require(hold.reached())
        audio.revoke()
        audio.authorize(Self.authorization())
        #expect(audio.ingressReservations == (1, AudioFixture.accessUnits[0].count))
        hold.resume()
        audio.sync()
        #expect(audio.snapshot.counters.scheduled == 0 && audio.ingressReservations == (0, 0))
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) == 0)
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.counters.scheduled == 4)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
    }

    @Test func reservationsIncludeInFlightAndOldAuthorizationNeverBecomesTheNewOne() async throws {
        let hold = PausedAudioWork(), calls = Atomic<Int>(0)
        let session = FakeAudioSession()
        let p = AudioPipeline(session: session, output: .offline,
                              decodeAccessUnit: { decoder, unit in
                                  if calls.add(1, ordering: .relaxed).oldValue == 0 { hold.pause() }
                                  return try decoder.decode(unit)
                              })
        defer { hold.resume(); p.terminate() }
        let old = Self.authorization(), fresh = Self.authorization()
        p.authorize(old); p.sync()
        let maxUnit = [UInt8](repeating: 0xA5, count: HPSSAudio.maxAccessUnitBytes)
        #expect(p.accept(packet(1, payload: maxUnit)))
        try #require(hold.reached())
        for seq in UInt16(2)...32 { #expect(p.accept(packet(seq, payload: maxUnit))) }
        #expect(p.ingressReservations == (32, 49_152) && !p.accept(packet(33)))
        p.revoke()
        p.authorize(old)
        #expect(!p.accept(packet(34)))
        p.authorize(fresh)
        #expect(p.ingressReservations == (1, 1536))
        hold.resume()
        p.sync()
        #expect(p.ingressReservations == (0, 0))
        #expect(calls.load(ordering: .relaxed) == 1 && p.snapshot.counters.scheduled == 0)
        #expect(p.accept(packet(50, payload: AudioFixture.accessUnits[3])))
        p.sync()
        #expect(p.snapshot.counters.scheduled == 1)
        async let one: Void = p.stopAndDrain()
        async let two: Void = p.stopAndDrain()
        _ = await (one, two)
        #expect(p.ingressReservations == (0, 0) && !p.snapshot.running)
        #expect(session.deactivations.load(ordering: .relaxed) == 2)
    }

    @Test func rejectedAndTrimmedBlocksReleaseIngressReservations() {
        let (p, _) = make()
        defer { p.terminate() }
        p.mediaGenerationChanged(2)
        p.authorize(Self.authorization()); p.sync()
        #expect(!p.accept(packet(1, generation: 1)))
        #expect(p.ingressReservations == (0, 0))
        #expect(p.accept(packet(1, generation: 2, payload: Array(repeating: 0xA5, count: 200))))
        p.sync()
        #expect(p.snapshot.counters.decodeErrors == 1 && p.ingressReservations == (0, 0))
        for seq in UInt16(2)...20 {
            #expect(p.accept(packet(seq, generation: 2, arrival: UInt64(seq) * 10 * ms)))
            p.sync()
        }
        #expect(p.snapshot.playout.dropped > 0 && p.ingressReservations == (0, 0))
    }

    @Test func negativeStartupPrimesAndKeepsTheNextThreeAccessUnits() {
        let session = FakeAudioSession(ioBufferDuration: 1024 / HPSSAudio.sampleRate)
        let sample = Atomic<AVAudioFramePosition>(-2048)
        let p = AudioPipeline(session: session, output: .offline,
                              clockSample: { sample.load(ordering: .relaxed) })
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()

        // Capture 225830Z saw the same render sample for the four startup AUs.
        expectStartup(p, firstSample: 480, target: 2528)
        sample.store(0, ordering: .relaxed)
        #expect(p.accept(packet(5, arrival: 40 * ms, payload: AudioFixture.accessUnits[4])))
        p.sync()
        let s = p.snapshot
        #expect(s.playout.dropped == 0 && s.playout.primes == 1)
        #expect(s.counters.decoded == 5 && s.counters.scheduled == 5)
        #expect(s.scheduledEnd == 480 + 448 + 4 * 480)
    }

    @Test(arguments: [AVAudioFramePosition(0), 1024])
    func nonnegativeStartupKeepsTheFullPrimingTarget(_ sample: AVAudioFramePosition) {
        let session = FakeAudioSession(ioBufferDuration: 1024 / HPSSAudio.sampleRate)
        let p = AudioPipeline(session: session, output: .offline, clockSample: { sample })
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        expectStartup(p, firstSample: sample + 2528, target: 2528)
    }

    private enum PrimingReset: CaseIterable, Sendable { case stream, engine, offer }

    @Test(arguments: PrimingReset.allCases)
    private func startupPrimesAfterResetWithTheShorterRouteTarget(_ reset: PrimingReset) {
        let p = AudioPipeline(session: FakeAudioSession(), output: .offline, clockSample: { -2048 })
        defer { p.terminate() }
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization()); p.sync()
        // The 960-frame target falls wholly inside pre-roll. Sample zero is
        // the first valid start, and the excess pre-roll must not cause drops.
        expectStartup(p, firstSample: 0, target: 960)

        switch reset {
        case .stream:
            expectStartup(p, firstSample: 0, target: 960, ssrc: 0xA0D1_0002)
        case .engine:
            p.queue.sync { p.handle(.engineConfigurationChanged) }
            #expect(p.snapshot.scheduledEnd == 0)
            expectStartup(p, firstSample: 0, target: 960)
        case .offer:
            p.mediaSuspended(offer: 1)
            p.sync()
            #expect(p.snapshot.scheduledEnd == 0 && !p.snapshot.playing)
            p.mediaGenerationChanged(2)
            p.sync()
            expectStartup(p, firstSample: 0, target: 960, offer: 2)
        }
    }

    private func expectStartup(_ p: AudioPipeline, firstSample: AVAudioFramePosition, target: Int,
                               offer: UInt64 = 1, ssrc: UInt32 = 0xA0D1_0001) {
        let before = p.snapshot
        for (i, unit) in AudioFixture.accessUnits.prefix(4).enumerated() {
            #expect(p.accept(packet(UInt16(i + 1), ssrc: ssrc, generation: offer, arrival: UInt64(i) * 10 * ms, payload: unit)))
            p.sync()
            let s = p.snapshot
            #expect(s.target == target)
            #expect(s.playout.primes == before.playout.primes + 1)
            #expect(s.playout.dropped == before.playout.dropped)
            #expect(s.counters.decoded == before.counters.decoded + i + 1)
            #expect(s.counters.scheduled == before.counters.scheduled + i + 1)
            #expect(s.scheduledEnd == firstSample + 448 + AVAudioFramePosition(i * 480))
        }
    }

    @Test func negativeInitialPlayerTimePrimesAgainAfterEngineReconfiguration() throws {
        let session = FakeAudioSession()
        let p = AudioPipeline(session: session, output: .offline, clockSample: { -2048 })
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        #expect(p.accept(packet(1, payload: AudioFixture.accessUnits[3])))
        p.sync()
        let first = p.snapshot
        #expect(first.playout.primes == 1 && first.playout.lengthened == 0)
        #expect(first.target == 960 && first.scheduledEnd == 448) // Prime at sample zero, then schedule 448 frames.
        p.queue.sync { p.handle(.engineConfigurationChanged) }
        #expect(p.snapshot.counters.starts == 2 && p.snapshot.scheduledEnd == 0)
        #expect(session.activations.load(ordering: .relaxed) == 1)
        let silent = try #require(p.renderOffline(4096))
        #expect((0..<Int(silent.frameLength)).allSatisfy { silent.floatChannelData![0][$0] == 0 })
        #expect(p.accept(packet(2, payload: AudioFixture.accessUnits[3])))
        p.sync()
        #expect(p.snapshot.playout.primes == 2 && p.snapshot.playout.lengthened == 0)
    }

    @Test func revocationWhileResetRebuildsCannotRestartTheEngine() throws {
        let hold = PausedAudioWork(), builds = Atomic<Int>(0)
        let session = FakeAudioSession()
        let p = AudioPipeline(session: session, output: .offline, makeDecoder: {
            if builds.add(1, ordering: .relaxed).oldValue == 1 { hold.pause() }
            return try AACELDDecoder()
        })
        defer { hold.resume(); p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        p.queue.async { p.handle(.mediaServicesReset) }
        try #require(hold.reached())
        p.revoke()
        p.enqueueSystemEvent(.engineConfigurationChanged)
        hold.resume()
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting)
        #expect(p.snapshot.counters.starts == 1 && session.activations.load(ordering: .relaxed) == 1)
    }

    @Test func revokeDuringEngineReconfigurationCannotArmTheRestart() throws {
        let hold = PausedAudioWork(), park = Atomic(false)
        let session = FakeAudioSession(onReadIODuration: {
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
        })
        let (audio, _) = make(session: session)
        defer { hold.resume(); audio.terminate() }
        audio.mediaGenerationChanged(1)
        audio.authorize(Self.authorization()); audio.sync()
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        let engine = try #require(audio.offlineEngine)
        park.store(true, ordering: .releasing)
        audio.enqueueSystemEvent(.engineConfigurationChanged)
        try #require(hold.reached())
        #expect(!engine.isRunning)
        audio.revoke()
        #expect(!audio.accept(packet(5)) && !hold.timedOut)
        hold.resume()
        audio.sync()
        let stopped = audio.snapshot
        #expect(!stopped.running && !stopped.playing && stopped.counters.starts == 1)
        #expect(stopped.counters.configurationChanges == 1 && stopped.counters.scheduled == 4)
        audio.authorize(Self.authorization()); audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.counters.starts == 2)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) == 0)
    }

    @Test(arguments: [RevocationReason.voluntaryClose, .background, .deviceLock])
    @MainActor func lifetimeRevocationFlushesPreviouslyScheduledPCM(_ reason: RevocationReason) async throws {
        let session = FakeAudioSession()
        let (p, _) = make(session: session)
        let lifetime = SessionLifetime(profileID: UUID())
        lifetime.register("audio", grant: p.authorize, revoke: { _ in p.revoke() }, end: p.terminate)
        defer { lifetime.end(.sessionEnded) }
        lifetime.sessionEstablished(); p.sync()
        #expect(p.accept(packet(1, payload: AudioFixture.accessUnits[4])))
        p.sync()
        #expect(p.snapshot.counters.scheduled == 1)
        switch reason {
        case .voluntaryClose: lifetime.end(reason)
        case .background: lifetime.sceneSignal(.didEnterBackground)
        case .deviceLock: lifetime.sceneSignal(.protectedDataWillBecomeUnavailable)
        case .sessionEnded: Issue.record("Unexpected test case")
        }
        #expect(!p.accept(packet(2)))
        p.sync()
        #expect(!p.snapshot.playing && session.deactivations.load(ordering: .relaxed) == 1)
        if !lifetime.ended {
            lifetime.sceneSignal(.didActivate)
            lifetime.sceneSignal(.protectedDataDidBecomeAvailable)
            p.sync()
            let out = try #require(p.renderOffline(4096))
            #expect((0..<Int(out.frameLength)).allSatisfy { out.floatChannelData![0][$0] == 0 })
        }
        await p.stopAndDrain()
        #expect(!p.snapshot.running && p.ingressReservations == (0, 0))
    }

    @Test(arguments: [RevocationReason.deviceLock, .background, .voluntaryClose])
    @MainActor func lifetimeRevocationStopsQueuedPCMWhileDecodeIsParked(_ reason: RevocationReason) async throws {
        let hold = PausedAudioWork(), park = Atomic(false)
        let session = FakeAudioSession()
        let audio = AudioPipeline(session: session, output: .offline,
                                  decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
            return block
        })
        let lifetime = SessionLifetime(profileID: UUID())
        lifetime.register("audio", grant: audio.authorize, revoke: { _ in audio.revoke() }, end: audio.terminate)
        defer { hold.resume(); lifetime.end(.sessionEnded) }
        audio.mediaGenerationChanged(1)
        lifetime.sessionEstablished()
        audio.sync()
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)
        let engine = try #require(audio.offlineEngine)
        let format = try #require(HPSSAudio.pcmFormat())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        park.store(true, ordering: .releasing)
        #expect(audio.accept(packet(5, arrival: 50 * ms, payload: AudioFixture.accessUnits[4])))
        try #require(hold.reached())

        switch reason {
        case .deviceLock: lifetime.sceneSignal(.protectedDataWillBecomeUnavailable)
        case .background: lifetime.sceneSignal(.didEnterBackground)
        case .voluntaryClose: lifetime.end(.voluntaryClose)
        case .sessionEnded: Issue.record("Unexpected test case")
        }
        #expect(!audio.accept(packet(6, arrival: 60 * ms, payload: AudioFixture.accessUnits[5])))
        #expect(engine.manualRenderingSampleTime == 0)
        #expect(try engine.renderOffline(4096, to: buffer) == .success && buffer.frameLength == 4096)
        #expect(nonSilentFrames(buffer) == 0 && !hold.timedOut)

        if reason == .voluntaryClose {
            let drained = Atomic(false)
            let drain = Task { await audio.stopAndDrain(); drained.store(true, ordering: .releasing) }
            try await Task.sleep(for: .milliseconds(100))
            let earlyDrain = drained.load(ordering: .acquiring)
            #expect(!earlyDrain && !hold.timedOut)
            hold.resume()
            await drain.value
            let completedDrain = drained.load(ordering: .acquiring)
            #expect(completedDrain)
            let final = audio.snapshot
            #expect(!final.running && !final.playing && final.counters.scheduled == 4)
            #expect(audio.ingressReservations == (0, 0))
        } else {
            if reason == .deviceLock { lifetime.sceneSignal(.protectedDataDidBecomeAvailable) }
            else { lifetime.sceneSignal(.didActivate) }
            hold.resume()
            audio.sync()
            #expect(audio.snapshot.counters.scheduled == 4)
            let stale = try #require(audio.renderOffline(4096))
            #expect(nonSilentFrames(stale) == 0)
            for seq: UInt16 in 1...4 {
                #expect(audio.accept(packet(seq, arrival: UInt64(100 + Int(seq) * 10) * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
                audio.sync()
            }
            #expect(audio.snapshot.counters.scheduled == 8)
            let resumed = try #require(audio.renderOffline(4096))
            #expect(nonSilentFrames(resumed) > 0)
            await audio.stopAndDrain()
            #expect(!audio.snapshot.running && audio.ingressReservations == (0, 0))
        }
    }

    @Test func interruptionDuringOfferChangeDoesNotLeaveStoppedPipelineAccepting() throws {
        let hold = PausedAudioWork(), park = Atomic(false)
        let audio = AudioPipeline(session: FakeAudioSession(), output: .offline,
                                  decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
            return block
        })
        defer { hold.resume(); audio.terminate() }
        audio.mediaGenerationChanged(1)
        audio.authorize(Self.authorization())
        audio.sync()
        park.store(true, ordering: .releasing)
        #expect(audio.accept(packet(1, generation: 1, payload: AudioFixture.accessUnits[0])))
        try #require(hold.reached())
        audio.enqueueSystemEvent(.interruptionBegan)
        audio.mediaGenerationChanged(2)
        hold.resume()
        audio.sync()
        let stopped = audio.snapshot
        #expect(!stopped.running && !stopped.playing && !stopped.accepting)
        #expect(audio.state == .interrupted(.system))
        #expect(!audio.accept(packet(1, generation: 2, payload: AudioFixture.accessUnits[0])))
        #expect(audio.ingressReservations == (0, 0))
        audio.resume()
        audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.accepting)
        #expect(audio.accept(packet(2, generation: 2, payload: AudioFixture.accessUnits[1])))
        audio.sync()
        #expect(audio.snapshot.counters.scheduled == 1)
    }

    private enum SystemStopDuringActivation: CaseIterable, Sendable {
        case interruptionBegan, routeLost
        var event: AudioSessionEvent { self == .interruptionBegan ? .interruptionBegan : .routeLost }
        var expectedState: AudioPipeline.State {
            self == .interruptionBegan ? .interrupted(.system) : .interrupted(.routeLost)
        }
    }

    private enum OfferReconfigurationMode: CaseIterable, Sendable {
        case directOfferChange, transportReconfigure, unchangedOffer
    }

    /// Reproduces the activation-held interleaving where `.interruptionBegan` or
    /// `.routeLost` arrives while `AudioSessionControlling.activate()` is parked
    /// and a newer offer supersedes the in-progress activation (both directly and
    /// via `MediaTransport.configure`), alongside the unchanged-offer control.
    @Test(arguments: SystemStopDuringActivation.allCases, OfferReconfigurationMode.allCases)
    private func systemStopDuringActivationIsPreservedAcrossOfferTransition(
        _ stop: SystemStopDuringActivation, _ mode: OfferReconfigurationMode
    ) throws {
        let hold = PausedAudioWork(), park = Atomic(true)
        let session = FakeAudioSession(onActivate: {
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
        })
        let audio = AudioPipeline(session: session, output: .offline)
        let media = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                  mailbox: DesktopUpdateMailbox(), evidence: .disabled, avClock: audio.avClock)
        let transport = MediaTransport(pipeline: media, evidence: .disabled, tiles: 1, audio: audio)
        let offer1 = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        let offer2 = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        defer { hold.resume(); media.queue.sync { transport.stop() }; audio.terminate() }

        let targetOffer: UInt64 = mode == .unchangedOffer ? 1 : 2
        if mode == .transportReconfigure {
            try media.queue.sync {
                try transport.configure(keys: offer1.keys, videoSSRC: offer1.videoSSRC, audioSSRC: offer1.audioSSRC, offerID: 1)
            }
            audio.sync()
        } else {
            audio.mediaGenerationChanged(1)
            audio.sync()
        }

        audio.authorize(Self.authorization())
        try #require(hold.reached())

        // Deliver the system stop event while activation is still in progress.
        audio.enqueueSystemEvent(stop.event)
        switch mode {
        case .directOfferChange:
            audio.mediaGenerationChanged(2)
        case .transportReconfigure:
            try media.queue.sync {
                try transport.configure(keys: offer2.keys, videoSSRC: offer2.videoSSRC, audioSSRC: offer2.audioSSRC, offerID: 2)
            }
        case .unchangedOffer:
            break
        }

        hold.resume()
        audio.sync()

        let stopped = audio.snapshot
        #expect(!stopped.running && !stopped.playing && !stopped.accepting)
        #expect(stopped.counters.starts == 0 && stopped.counters.scheduled == 0)
        #expect(audio.state == stop.expectedState)
        #expect(session.activations.load(ordering: .relaxed) == 1 && session.deactivations.load(ordering: .relaxed) == 1)

        // Four valid audio AUs for the active offer must be refused without resume/re-authorization.
        for i in 0..<4 {
            #expect(!audio.accept(packet(UInt16(i + 1), generation: targetOffer,
                                         arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
        }
        audio.sync()
        #expect(audio.snapshot.counters.scheduled == 0 && audio.ingressReservations == (0, 0))

        // Negative recovery controls must keep playback stopped.
        switch stop {
        case .interruptionBegan:
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: false))
        case .routeLost:
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        }
        audio.sync()
        #expect(!audio.snapshot.running && !audio.snapshot.accepting && audio.state == stop.expectedState)

        // Legitimate recovery restarts the current offer cleanly and renders non-silent PCM.
        switch stop {
        case .interruptionBegan:
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        case .routeLost:
            audio.resume()
        }
        audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.accepting)
        #expect(audio.snapshot.counters.starts == 1 && session.activations.load(ordering: .relaxed) == 2)
        for i in 0..<4 {
            #expect(audio.accept(packet(UInt16(i + 1), generation: targetOffer,
                                        arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
            audio.sync()
        }
        #expect(audio.snapshot.counters.scheduled == 4)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
    }

    @Test(arguments: SystemStopDuringActivation.allCases)
    private func systemStopAcrossOfferChangeWhileAlreadyRunningOrSuspendedPreservesInterruption(
        _ stop: SystemStopDuringActivation
    ) throws {
        // Control 1: already running when stop + offer change race while decode is parked.
        do {
            let hold = PausedAudioWork(), park = Atomic(false)
            let audio = AudioPipeline(session: FakeAudioSession(), output: .offline,
                                      decodeAccessUnit: { decoder, unit in
                let block = try decoder.decode(unit)
                if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
                return block
            })
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting)
            park.store(true, ordering: .releasing)
            #expect(audio.accept(packet(1, generation: 1, payload: AudioFixture.accessUnits[0])))
            try #require(hold.reached())
            audio.enqueueSystemEvent(stop.event)
            audio.mediaGenerationChanged(2)
            hold.resume()
            audio.sync()
            let stopped = audio.snapshot
            #expect(!stopped.running && !stopped.playing && !stopped.accepting)
            #expect(audio.state == stop.expectedState)
            #expect(!audio.accept(packet(1, generation: 2, payload: AudioFixture.accessUnits[0])))
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting)
        }

        // Control 2: stopped after mediaSuspended while authorized, then stop event before offer 2.
        do {
            let hold = PausedAudioWork(), park = Atomic(true)
            let session = FakeAudioSession(onActivate: {
                if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
            })
            let audio = AudioPipeline(session: session, output: .offline)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            try #require(hold.reached())
            audio.mediaSuspended(offer: 1)
            hold.resume()
            audio.sync()
            #expect(!audio.snapshot.running && !audio.snapshot.accepting)
            audio.enqueueSystemEvent(stop.event)
            audio.mediaGenerationChanged(2)
            audio.sync()
            #expect(!audio.snapshot.running && !audio.snapshot.accepting && audio.state == stop.expectedState)
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting)
        }

        // Control 3: unauthorized pipeline ignores system stop events and starts cleanly when later authorized.
        do {
            let (audio, _) = make()
            defer { audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.sync()
            audio.enqueueSystemEvent(stop.event)
            audio.sync()
            #expect(audio.state == .negotiating)
            audio.authorize(Self.authorization())
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting)
        }
    }

    private enum ReactivationOfferTiming: CaseIterable, Sendable {
        case sameOffer, offerBeforeThrow, offerAfterThrow, transportReconfigureBeforeThrow
    }

    /// Reproduces transient `AudioSessionControlling.activate()` failure during
    /// reactivation when a concurrent system stop (`.interruptionBegan` or
    /// `.routeLost`) arrives across same-offer and offer-transition timings.
    @Test(arguments: SystemStopDuringActivation.allCases, ReactivationOfferTiming.allCases)
    private func throwingReactivationDuringSystemStopPreservesStopReasonAndRecovery(
        _ stop: SystemStopDuringActivation, _ timing: ReactivationOfferTiming
    ) throws {
        let hold = PausedAudioWork(), attempts = Atomic(0)
        let session = FakeAudioSession(onActivate: {
            if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                hold.pause()
                throw NSError(domain: NSOSStatusErrorDomain,
                              code: Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue))
            }
        })
        let audio = AudioPipeline(session: session, output: .offline)
        let media = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                  mailbox: DesktopUpdateMailbox(), evidence: .disabled, avClock: audio.avClock)
        let transport = MediaTransport(pipeline: media, evidence: .disabled, tiles: 1, audio: audio)
        let offer1 = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        let offer2 = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test", audio: .requested)
        defer { hold.resume(); media.queue.sync { transport.stop() }; audio.terminate() }

        let targetOffer: UInt64 = timing == .sameOffer ? 1 : 2
        if timing == .transportReconfigureBeforeThrow {
            try media.queue.sync {
                try transport.configure(keys: offer1.keys, videoSSRC: offer1.videoSSRC, audioSSRC: offer1.audioSSRC, offerID: 1)
            }
            audio.sync()
        } else {
            audio.mediaGenerationChanged(1)
            audio.sync()
        }

        audio.authorize(Self.authorization())
        audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.playing && audio.snapshot.accepting)
        #expect(attempts.load(ordering: .acquiring) == 1)

        audio.enqueueSystemEvent(.interruptionBegan)
        audio.sync()
        #expect(!audio.snapshot.running && audio.state == .interrupted(.system))

        audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        try #require(hold.reached())

        audio.enqueueSystemEvent(stop.event)
        switch timing {
        case .offerBeforeThrow:
            audio.mediaGenerationChanged(2)
        case .transportReconfigureBeforeThrow:
            try media.queue.sync {
                try transport.configure(keys: offer2.keys, videoSSRC: offer2.videoSSRC, audioSSRC: offer2.audioSSRC, offerID: 2)
            }
        case .sameOffer, .offerAfterThrow:
            break
        }
        hold.resume()
        audio.sync()
        if timing == .offerAfterThrow {
            audio.mediaGenerationChanged(2)
            audio.sync()
        }

        let stopped = audio.snapshot
        #expect(!hold.timedOut)
        #expect(!stopped.running && !stopped.playing && !stopped.accepting)
        #expect(audio.state == stop.expectedState)
        #expect(attempts.load(ordering: .acquiring) == 2)
        for i in 0..<4 {
            #expect(!audio.accept(packet(UInt16(i + 1), generation: targetOffer,
                                         arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
        }
        audio.sync()
        #expect(audio.snapshot.counters.scheduled == 0 && audio.ingressReservations == (0, 0))

        // Negative recommendation keeps playback stopped in the same interruption state.
        audio.enqueueSystemEvent(.interruptionEnded(shouldResume: false))
        audio.sync()
        #expect(!audio.snapshot.running && !audio.snapshot.playing && !audio.snapshot.accepting)
        #expect(audio.state == stop.expectedState && attempts.load(ordering: .acquiring) == 2)

        // Positive recommendation restores a system interruption, but never bypasses route loss.
        audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        audio.sync()
        switch stop {
        case .interruptionBegan:
            #expect(audio.snapshot.running && audio.snapshot.playing && audio.snapshot.accepting)
            #expect(attempts.load(ordering: .acquiring) == 3 && session.activations.load(ordering: .relaxed) == 2)
        case .routeLost:
            #expect(!audio.snapshot.running && !audio.snapshot.playing && !audio.snapshot.accepting)
            #expect(audio.state == .interrupted(.routeLost) && attempts.load(ordering: .acquiring) == 2)
            #expect(!audio.accept(packet(1, generation: targetOffer, payload: AudioFixture.accessUnits[0])))
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.playing && audio.snapshot.accepting)
            #expect(attempts.load(ordering: .acquiring) == 3 && session.activations.load(ordering: .relaxed) == 2)
        }

        if targetOffer == 2 {
            #expect(!audio.accept(packet(1, generation: 1, payload: AudioFixture.accessUnits[0])))
        }
        for i in 0..<4 {
            #expect(audio.accept(packet(UInt16(i + 1), generation: targetOffer,
                                        arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
            audio.sync()
        }
        #expect(audio.snapshot.counters.scheduled == 4)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
    }

    /// Independent activation errors remain `.failed` until explicit manual Resume,
    /// while media-services loss, combined interruption+route-loss, revocation,
    /// disable, and media suspension during a throwing activation preserve their
    /// respective lifecycle gates without resurrecting stale authorization.
    @Test func throwingActivationDistinguishesIndependentFailuresAndLifecycleControls() throws {
        let insufficientPriority = NSError(domain: NSOSStatusErrorDomain,
                                           code: Int(AVAudioSession.ErrorCode.insufficientPriority.rawValue))

        // 1. Genuine independent transient failure (no concurrent system stop) stays .failed until manual Resume.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            hold.resume()
            audio.sync()
            if case .failed = audio.state {} else {
                Issue.record("Independent activation error must report .failed, got \(String(describing: audio.state))")
            }
            #expect(!audio.snapshot.running && !audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 2)
            audio.mediaGenerationChanged(2)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: false))
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.sync()
            if case .failed = audio.state {} else {
                Issue.record("Independent failure must not clear on offer change or shouldResume, got \(String(describing: audio.state))")
            }
            #expect(!audio.snapshot.running && !audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 2)
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.playing && audio.snapshot.accepting)
            #expect(attempts.load(ordering: .acquiring) == 3)
            for i in 0..<4 {
                #expect(audio.accept(packet(UInt16(i + 1), generation: 2,
                                            arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
                audio.sync()
            }
            #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
        }

        // 2. Persistent independent failure stays .failed across manual Resume until the session stops refusing.
        do {
            let session = FakeAudioSession()
            let (audio, _) = make(session: session)
            defer { audio.terminate() }
            audio.mediaGenerationChanged(1)
            session.refuses.store(true, ordering: .releasing)
            audio.authorize(Self.authorization())
            audio.sync()
            if case .failed = audio.state {} else { Issue.record("Expected .failed on persistent refusal") }
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.resume()
            audio.sync()
            if case .failed = audio.state {} else { Issue.record("Still refusing session must remain .failed") }
            #expect(!audio.snapshot.running && !audio.snapshot.accepting)
            session.refuses.store(false, ordering: .releasing)
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting)
        }

        // 3. Combined .interruptionBegan + .routeLost during throwing activation preserves sticky route loss.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.enqueueSystemEvent(.routeLost)
            hold.resume()
            audio.sync()
            #expect(audio.state == .interrupted(.routeLost) && !audio.snapshot.running)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.sync()
            #expect(audio.state == .interrupted(.routeLost) && !audio.snapshot.running && attempts.load(ordering: .acquiring) == 2)
            audio.resume()
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 3)
        }

        // 4. Media services lost during throwing activation publishes .interrupted(.mediaServices) and recovers on reset.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            audio.enqueueSystemEvent(.mediaServicesLost)
            hold.resume()
            audio.sync()
            #expect(audio.state == .interrupted(.mediaServices) && !audio.snapshot.running)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.resume()
            audio.sync()
            #expect(audio.state == .interrupted(.mediaServices) && !audio.snapshot.running && attempts.load(ordering: .acquiring) == 2)
            audio.enqueueSystemEvent(.mediaServicesReset)
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 3)
            for i in 0..<4 {
                #expect(audio.accept(packet(UInt16(i + 1), generation: 1,
                                            arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
                audio.sync()
            }
            #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
        }

        // 5. Revocation during throwing activation + system stop cannot be resurrected by shouldResume or stale auth.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            let staleAuth = Self.authorization()
            audio.authorize(staleAuth)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.revoke()
            hold.resume()
            audio.sync()
            #expect(!audio.snapshot.running && !audio.snapshot.accepting)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.mediaGenerationChanged(2)
            audio.authorize(staleAuth)
            audio.sync()
            #expect(!audio.snapshot.running && !audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 2)
            audio.authorize(Self.authorization())
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 3)
            #expect(!audio.accept(packet(1, generation: 1, payload: AudioFixture.accessUnits[0])))
            for i in 0..<4 {
                #expect(audio.accept(packet(UInt16(i + 1), generation: 2,
                                            arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
                audio.sync()
            }
            #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
        }

        // 6. Disabling during throwing activation + system stop remains .disabled until re-enabled.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.setEnabled(false)
            hold.resume()
            audio.sync()
            #expect(audio.state == .disabled && !audio.snapshot.running && !audio.snapshot.accepting)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.resume()
            audio.sync()
            #expect(audio.state == .disabled && !audio.snapshot.running && attempts.load(ordering: .acquiring) == 2)
            audio.setEnabled(true)
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 3)
        }

        // 7. Media suspension + system stop during throwing activation stays interrupted across offer 2 until shouldResume.
        do {
            let hold = PausedAudioWork(), attempts = Atomic(0)
            let session = FakeAudioSession(onActivate: {
                if attempts.add(1, ordering: .sequentiallyConsistent).newValue == 2 {
                    hold.pause()
                    throw insufficientPriority
                }
            })
            let (audio, _) = make(session: session)
            defer { hold.resume(); audio.terminate() }
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            audio.enqueueSystemEvent(.interruptionBegan)
            audio.sync()
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            try #require(hold.reached())
            audio.mediaSuspended(offer: 1)
            audio.enqueueSystemEvent(.interruptionBegan)
            hold.resume()
            audio.sync()
            #expect(audio.state == .interrupted(.system) && !audio.snapshot.running && !audio.snapshot.accepting)
            audio.mediaGenerationChanged(2)
            audio.sync()
            #expect(audio.state == .interrupted(.system) && !audio.snapshot.running && !audio.snapshot.accepting)
            audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
            audio.sync()
            #expect(audio.snapshot.running && audio.snapshot.accepting && attempts.load(ordering: .acquiring) == 3)
            for i in 0..<4 {
                #expect(audio.accept(packet(UInt16(i + 1), generation: 2,
                                            arrival: UInt64(i) * 10 * ms, payload: AudioFixture.accessUnits[i])))
                audio.sync()
            }
            #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
        }
    }

    private enum ParkedSystemStop: CaseIterable, Sendable {
        case interruptionBegan, routeLost, mediaServicesLost
        var event: AudioSessionEvent {
            switch self {
            case .interruptionBegan: .interruptionBegan
            case .routeLost: .routeLost
            case .mediaServicesLost: .mediaServicesLost
            }
        }
        var expectedState: AudioPipeline.State {
            switch self {
            case .interruptionBegan: .interrupted(.system)
            case .routeLost: .interrupted(.routeLost)
            case .mediaServicesLost: .interrupted(.mediaServices)
            }
        }
    }

    /// System stop notifications never acquire `pcmCommit` on the delivering
    /// thread; instead they fence new commits atomically and unschedule queued
    /// PCM on `stopQueue` independently of a parked AAC-ELD decode on `queue`.
    @Test(arguments: ParkedSystemStop.allCases)
    private func systemStopRevokesQueuedPCMWhileDecodeIsParked(_ stop: ParkedSystemStop) throws {
        let hold = PausedAudioWork(), park = Atomic(false)
        let session = FakeAudioSession()
        let audio = AudioPipeline(session: session, output: .offline,
                                  decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
            return block
        })
        defer { hold.resume(); audio.terminate() }
        audio.mediaGenerationChanged(1)
        audio.authorize(Self.authorization())
        audio.sync()
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)
        let engine = try #require(audio.offlineEngine)
        let format = try #require(HPSSAudio.pcmFormat())
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))

        park.store(true, ordering: .releasing)
        #expect(audio.accept(packet(5, arrival: 50 * ms, payload: AudioFixture.accessUnits[4])))
        try #require(hold.reached())

        audio.enqueueSystemEvent(stop.event)
        audio.stopQueue.sync {} // Wait only for the dedicated stop queue; worker decode remains parked.
        #expect(engine.manualRenderingSampleTime == 0)
        #expect(try engine.renderOffline(4096, to: buffer) == .success && buffer.frameLength == 4096)
        #expect(nonSilentFrames(buffer) == 0 && !hold.timedOut)

        hold.resume()
        audio.sync()
        let stopped = audio.snapshot
        #expect(!stopped.running && !stopped.playing && !stopped.accepting)
        #expect(stopped.counters.scheduled == 4 && audio.state == stop.expectedState)

        switch stop {
        case .interruptionBegan: audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        case .routeLost: audio.resume()
        case .mediaServicesLost: audio.enqueueSystemEvent(.mediaServicesReset)
        }
        audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.accepting)
        let stale = try #require(audio.renderOffline(4096))
        #expect(nonSilentFrames(stale) == 0)
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(100 + Int(seq) * 10) * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.counters.scheduled == 8)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
    }

    @Test func delayedSystemStopCannotStopAPlayerStartedAfterRecovery() throws {
        let (audio, _) = make()
        defer { audio.terminate() }
        audio.mediaGenerationChanged(1)
        audio.authorize(Self.authorization())
        audio.sync()
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)

        // Hold the dedicated stop queue while the worker stops and recovers.
        audio.stopQueue.suspend()
        var stopQueueSuspended = true
        defer { if stopQueueSuspended { audio.stopQueue.resume() } }
        audio.enqueueSystemEvent(.interruptionBegan)
        audio.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        audio.sync()
        #expect(audio.snapshot.running && audio.snapshot.playing && audio.snapshot.accepting)
        for seq: UInt16 in 1...4 {
            #expect(audio.accept(packet(seq, arrival: UInt64(100 + Int(seq) * 10) * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            audio.sync()
        }
        #expect(audio.snapshot.counters.scheduled == 8)

        // Release the delayed stop task from the earlier interruption and verify the resumed player stays active.
        audio.stopQueue.resume()
        stopQueueSuspended = false
        audio.stopQueue.sync {}
        #expect(audio.snapshot.running && audio.snapshot.playing)
        #expect(nonSilentFrames(try #require(audio.renderOffline(4096))) > 0)
    }

    @Test func routeChangeResetsAudioCorrelationAndFencesPendingWork() throws {
        let a: UInt32 = 480_000, v: UInt32 = 240_000
        let ntpBase: UInt32 = 4_004_090_000

        // Run an identical parked-AU alignment twice: once without a route-change
        // notification (positive control: correlation succeeds) and once with a
        // pending equal-latency route change (fence suppresses correlation).
        func runParkedCase(enqueueRouteChange: Bool) throws -> (audio: AudioPipeline, session: FakeAudioSession,
                                                                anchor0: UInt64, parkedRenderHost: UInt64,
                                                                afterSync: UInt64) {
            let hold = PausedAudioWork(), park = Atomic(false)
            let renderHost = Atomic<UInt64>(0)
            let session = FakeAudioSession(outputLatency: 0.010, outputRouteIDs: ["route-A"])
            let audio = AudioPipeline(session: session, output: .offline,
                                      decodeAccessUnit: { decoder, unit in
                let block = try decoder.decode(unit)
                if park.exchange(false, ordering: .acquiringAndReleasing) { hold.pause() }
                return block
            }, clockSample: { 0 }, clockHostNanos: { renderHost.load(ordering: .acquiring) })
            defer { hold.resume() }

            let clock = audio.avClock
            audio.mediaGenerationChanged(1)
            audio.authorize(Self.authorization())
            audio.sync()
            clock.selectSource(.audio, ssrc: 7, offer: 1)
            clock.selectSource(.video, ssrc: 8, offer: 1)

            let originNow = DispatchTime.now().uptimeNanoseconds
            let anchor0 = originNow - 2_000 * ms
            let anchor1 = originNow - 1_000 * ms
            clock.senderReport(.init(ssrc: 7, ntpSeconds: ntpBase, ntpFraction: 0, rtpTimestamp: a), leg: .audio, offer: 1, received: anchor0)
            clock.senderReport(.init(ssrc: 8, ntpSeconds: ntpBase, ntpFraction: 0, rtpTimestamp: v), leg: .video, offer: 1, received: anchor0)
            clock.senderReport(.init(ssrc: 7, ntpSeconds: ntpBase + 1, ntpFraction: 0, rtpTimestamp: a + 48_000), leg: .audio, offer: 1, received: anchor1)
            clock.senderReport(.init(ssrc: 8, ntpSeconds: ntpBase + 1, ntpFraction: 0, rtpTimestamp: v + 24_000), leg: .video, offer: 1, received: anchor1)
            // Video sample at host +1.900 s presented at +1.980 s (80 ms display offset).
            clock.videoPresented(offer: 1, generation: 0, timestamp: v + 45_600, nanos: anchor0 + 1_980 * ms)

            // Forward-looking render host timestamp valid on route-A before any route change.
            let beforePark = DispatchTime.now().uptimeNanoseconds
            let parkedRenderHost = beforePark + 20 * ms
            renderHost.store(parkedRenderHost, ordering: .releasing)
            let packetElapsedMS = (beforePark - anchor0) / ms
            let alignedTimestamp = a &+ UInt32(packetElapsedMS * 48)

            park.store(true, ordering: .releasing)
            #expect(audio.accept(packet(1, ssrc: 7, generation: 1, arrival: beforePark,
                                        payload: AudioFixture.accessUnits[0], timestamp: alignedTimestamp)))
            try #require(hold.reached())
            if enqueueRouteChange {
                session.setRoute(routeIDs: ["route-B"])
                audio.enqueueSystemEvent(.routeChanged)
            }
            hold.resume()
            audio.sync()
            return (audio, session, anchor0, parkedRenderHost, DispatchTime.now().uptimeNanoseconds)
        }

        // Positive control: without .routeChanged, the parked AU correlates cleanly.
        let control = try runParkedCase(enqueueRouteChange: false)
        defer { control.audio.terminate() }
        #expect(control.audio.snapshot.counters.scheduled == 1)
        #expect(control.audio.snapshot.playout.correlated == 1)

        // Equivalent fenced case: pending .routeChanged suppresses correlation of the parked AU.
        let fenced = try runParkedCase(enqueueRouteChange: true)
        defer { fenced.audio.terminate() }
        #expect(fenced.audio.snapshot.counters.scheduled == 1)
        #expect(fenced.audio.snapshot.playout.correlated == 0)

        let clock = fenced.audio.avClock
        // handle(.routeChanged) raised the render boundary to at least max(now, parkedRenderHost),
        // rejecting the old route's forward-looking render timestamp even with equal latency.
        let staleMS = (fenced.afterSync - fenced.anchor0) / ms + 10
        let preRouteSample = clock.audioErrorFrames(
            offer: 1, ssrc: 7, timestamp: a &+ UInt32(staleMS * 48),
            now: fenced.anchor0 + (staleMS + 15) * ms, renderHostNanos: fenced.parkedRenderHost,
            playerSample: 0, startSample: 960, outputLatency: 0.010)
        #expect(preRouteSample == nil)

        // An earlier boundary cannot regress the monotonic route boundary.
        clock.audioRouteChanged(offer: 1, after: fenced.anchor0 + 1_000 * ms)
        let stillRejected = clock.audioErrorFrames(
            offer: 1, ssrc: 7, timestamp: a &+ UInt32((staleMS + 10) * 48),
            now: fenced.anchor0 + (staleMS + 25) * ms, renderHostNanos: fenced.parkedRenderHost,
            playerSample: 0, startSample: 960, outputLatency: 0.010)
        #expect(stillRejected == nil)

        // A fresh render pair strictly after the route boundary correlates on route-B (10 ms latency -> -40 ms = -1920 frames).
        let boundaryFloor = max(fenced.afterSync, fenced.parkedRenderHost)
        let freshMS = (boundaryFloor - fenced.anchor0) / ms + 40
        let freshRouteB = try #require(clock.audioErrorFrames(
            offer: 1, ssrc: 7, timestamp: a &+ UInt32(freshMS * 48),
            now: fenced.anchor0 + (freshMS + 15) * ms,
            renderHostNanos: fenced.anchor0 + (freshMS + 10) * ms,
            playerSample: 0, startSample: 960, outputLatency: 0.010))
        #expect(abs(freshRouteB + 1920) < 0.001)

        // Now jump latency 10 ms -> 90 ms on the same route UID and verify fresh seeding with preserved sender clocks.
        fenced.session.setRoute(latency: 0.090)
        fenced.audio.enqueueSystemEvent(.routeChanged)
        fenced.audio.sync()
        let afterLatencyJump = max(DispatchTime.now().uptimeNanoseconds, boundaryFloor)
        let s3MS = (afterLatencyJump - fenced.anchor0) / ms + 50
        let seeded = try #require(clock.audioErrorFrames(
            offer: 1, ssrc: 7, timestamp: a &+ UInt32(s3MS * 48),
            now: fenced.anchor0 + (s3MS + 15) * ms,
            renderHostNanos: fenced.anchor0 + (s3MS + 10) * ms,
            playerSample: 0, startSample: 960, outputLatency: 0.090))
        #expect(abs(seeded - 1920) < 0.001)
    }

    @Test func stalledAudioQueueRejectsSaturationAndInvalidAccessUnits() {
        let (p, _) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        p.queue.suspend()
        defer { p.queue.resume() }
        #expect(!p.accept(packet(0, payload: [])))
        #expect(!p.accept(packet(0, payload: Array(repeating: 0, count: 1537))))
        let unit = [UInt8](repeating: 0xA5, count: 1536)
        let admitted = (1...40).filter { p.accept(packet(UInt16($0), payload: unit)) }
        #expect(admitted == Array(1...32))
        p.revoke()
        #expect(!p.accept(packet(41)))
    }

    @Test func revokeWhileDecodingDoesNotCommitPCM() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let p = AudioPipeline(session: FakeAudioSession(), output: .offline,
                              decodeAccessUnit: { decoder, unit in
                                  entered.signal()
                                  _ = release.wait(timeout: .now() + .seconds(5))
                                  return try decoder.decode(unit)
                              })
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        #expect(p.accept(packet(1, payload: AudioFixture.accessUnits[3])))
        let parked = entered.wait(timeout: .now() + .seconds(3))
        p.revoke()
        release.signal()
        try #require(parked == .success)
        p.sync()
        #expect(p.snapshot.counters.scheduled == 0)
        p.authorize(Self.authorization()); p.sync()
        let out = try #require(p.renderOffline(4096))
        #expect((0..<Int(out.frameLength)).allSatisfy { out.floatChannelData![0][$0] == 0 })
    }

    @Test func headphonesUnpluggedDuringAnInterruptionNeedExplicitResume() {
        let (p, _) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        p.queue.sync {
            p.handle(.interruptionBegan)
            p.handle(.routeLost)
            p.handle(.interruptionEnded(shouldResume: true))
        }
        #expect(p.state == .interrupted(.routeLost) && !p.snapshot.running)
        p.resume(); p.sync()
        #expect(p.snapshot.running)
    }

    @Test func decoderRebuildFailureIsReportedAndCanBeRetried() throws {
        let fails = Atomic<Bool>(false)
        let p = AudioPipeline(session: FakeAudioSession(), output: .offline,
                              makeDecoder: {
                                  if fails.load(ordering: .relaxed) { throw AACELDDecoder.Failure.unsupported }
                                  return try AACELDDecoder()
                              })
        defer { p.terminate() }
        let states = Recorder<AudioPipeline.State>()
        p.bind { states.add($0) }
        p.authorize(Self.authorization()); p.sync()
        fails.store(true, ordering: .relaxed)
        p.queue.sync { p.handle(.mediaServicesReset) }
        if case .failed = states.all.last {} else { Issue.record("A decoder rebuild failure must offer Resume") }
        #expect(!p.snapshot.running)
        fails.store(false, ordering: .relaxed)
        p.resume(); p.sync()
        _ = play(p, count: 6)
        #expect(p.snapshot.running && states.all.last == .playing)
    }

    @Test func anIsolatedBadPacketAfterResumeDoesNotFailAudioAgain() {
        let (p, _) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization()); p.sync()
        let bad = [UInt8](repeating: 0xA5, count: 200)
        for i in 0..<AudioPipeline.decodeFailureLimit {
            #expect(p.accept(packet(UInt16(i), arrival: UInt64(i) * 10 * ms, payload: bad)))
            p.sync()
        }
        #expect(!p.snapshot.running)
        p.resume(); p.sync()
        #expect(p.accept(packet(0, payload: bad)))
        p.sync()
        #expect(p.snapshot.running)
        _ = play(p, count: 6)
        #expect(p.state == .playing)
    }

    private static var token: SessionToken { SessionToken(profileID: UUID(), generation: 7) }
    private static let nextOperation = Atomic<UInt64>(2_000_000)
    private static func authorization() -> FeatureAuthorization {
        FeatureAuthorization(session: token, operation: nextOperation.add(1, ordering: .relaxed).newValue)
    }

    private func make(enabled: Bool = true, session: FakeAudioSession = FakeAudioSession()) -> (AudioPipeline, Recorder<AudioPipeline.State>) {
        let pipeline = AudioPipeline(enabled: enabled, session: session, output: .offline)
        let states = Recorder<AudioPipeline.State>()
        pipeline.bind { states.add($0) }
        return (pipeline, states)
    }

    /// Feeds the fixture as a live stream: one access unit, then 10 ms rendered.
    private func play(_ p: AudioPipeline, from sequence: UInt16 = 1, generation: UInt64 = 1, count: Int = 18,
                      ssrc: UInt32 = 0xA0D1_0001) -> [Float] {
        var left: [Float] = []
        for i in 0..<count {
            let unit = AudioFixture.accessUnits[i % AudioFixture.accessUnits.count]
            _ = p.accept(packet(sequence &+ UInt16(i), ssrc: ssrc, generation: generation,
                                arrival: UInt64(i) * 10 * ms, payload: unit))
            p.sync()
            if let out = p.renderOffline(480) {
                left += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            }
        }
        return left
    }

    @Test func authorizedEnabledAudioPlaysAndRevocationClosesEverythingFirst() throws {
        let session = FakeAudioSession()
        let (p, states) = make(session: session)
        defer { p.terminate() }
        p.sync()
        #expect(states.all == [.negotiating])                               // enabled, not yet authorized
        #expect(!p.accept(packet(1)))                                       // nothing accepted before authorization
        let auth = Self.authorization()
        p.authorize(auth)
        p.sync()
        #expect(p.snapshot.running && p.snapshot.accepting && session.activations.load(ordering: .relaxed) == 1)
        let left = play(p)
        #expect(power(left[2400...], 1000) > 1e-3)                          // decoded audio reached the output
        #expect(states.all.contains(.playing))
        // Revocation: the gates close before revoke() returns, then everything stops.
        AudioPipeline.queue.suspend()
        let parked = p.accept(packet(40, payload: AudioFixture.accessUnits[3]))   // queued before the revocation
        p.revoke()
        #expect(!p.accept(packet(41)))
        AudioPipeline.queue.resume()
        p.sync()
        let s = p.snapshot
        #expect(parked && s.counters.stale == 1)                            // the parked packet never played
        #expect(!s.running && !s.accepting && p.renderOffline(480) == nil)
        #expect(session.deactivations.load(ordering: .relaxed) == 1)
        // A late re-delivery of the old authorization cannot restart it.
        p.authorize(auth)
        p.sync()
        #expect(!p.snapshot.running && !p.accept(packet(42)))
    }

    @Test func aFreshAuthorizationAfterRevocationStartsAFreshStream() throws {
        let (p, _) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        _ = play(p, count: 6)
        p.revoke()
        p.sync()
        p.authorize(Self.authorization())                                   // the scene returned: a new operation
        p.sync()
        #expect(p.snapshot.running && p.snapshot.accepting)
        let left = play(p, from: 1000, count: 18)
        #expect(power(left[2400...], 1000) > 1e-3)
        #expect(p.snapshot.counters.starts == 2)
    }

    @Test func muteSilencesWithoutStoppingAndDisableStopsAndReleasesTheSession() throws {
        let session = FakeAudioSession()
        let (p, states) = make(session: session)
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        _ = play(p, count: 8)
        p.setMuted(true)
        p.sync()
        let muted = play(p, from: 9, count: 10)
        // The mixer ramps the volume down over about 30 ms (no click), then exact silence;
        // the stream and its timing continue.
        #expect(muted.dropFirst(1920).allSatisfy { $0 == 0 } && p.snapshot.running)
        #expect(states.all.last == .muted)
        p.setMuted(false)
        p.setEnabled(false)
        #expect(!p.accept(packet(30)))                                      // closed at once
        p.sync()
        #expect(!p.snapshot.running && states.all.last == .disabled && session.deactivations.load(ordering: .relaxed) == 1)
        p.setEnabled(true)
        p.sync()
        #expect(p.snapshot.running && session.activations.load(ordering: .relaxed) == 2)
    }

    @Test func systemInterruptionResumesOnlyWhenRecommendedAndStillAuthorized() throws {
        let (p, states) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        _ = play(p, count: 4)
        p.queue.sync { p.handle(.interruptionBegan) }
        #expect(!p.snapshot.running && states.all.last == .interrupted(.system))
        p.queue.sync { p.handle(.interruptionEnded(shouldResume: false)) }
        #expect(!p.snapshot.running && states.all.last == .interrupted(.system))
        p.resume()                                                          // the user resumes explicitly
        p.sync()
        #expect(p.snapshot.running)
        p.queue.sync { p.handle(.interruptionBegan) }
        p.revoke()                                                          // e.g. background during the interruption
        p.sync()
        p.queue.sync { p.handle(.interruptionEnded(shouldResume: true)) }
        #expect(!p.snapshot.running)                                        // no recovery without authorization
        p.authorize(Self.authorization())
        p.sync()
        #expect(p.snapshot.running && states.all.last != .interrupted(.system))
    }

    @Test func lostRouteMediaServicesResetAndSessionRefusalAreHandled() throws {
        let session = FakeAudioSession()
        let (p, states) = make(session: session)
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        p.queue.sync { p.handle(.routeLost) }                               // headphones gone: never the speaker unasked
        #expect(!p.snapshot.running && states.all.last == .interrupted(.routeLost))
        p.resume()
        p.sync()
        #expect(p.snapshot.running)
        p.queue.sync { p.handle(.mediaServicesLost) }
        #expect(!p.snapshot.running && states.all.last == .interrupted(.mediaServices))
        p.queue.sync { p.handle(.mediaServicesReset) }
        #expect(p.snapshot.running && p.snapshot.counters.mediaServicesResets == 1)
        let left = play(p, count: 18)                                       // a rebuilt graph plays
        #expect(power(left[2400...], 1000) > 1e-3)
        p.revoke(); p.sync()
        session.refuses.store(true, ordering: .relaxed)
        p.authorize(Self.authorization())
        p.sync()
        guard case .failed = states.all.last else { Issue.record("expected a local failure, got \(String(describing: states.all.last))"); return }
        #expect(!p.snapshot.running)
    }

    @Test func aNewStreamOrOfferDiscardsWhatWasScheduledBefore() throws {
        let (p, _) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        _ = play(p, count: 6)
        p.mediaGenerationChanged(2)
        p.sync()
        #expect(p.snapshot.counters.restarts == 1)
        _ = play(p, from: 9000, generation: 2, count: 4, ssrc: 0xBEEF)
        #expect(p.snapshot.counters.restarts == 1)                          // the new offer's packets: no second restart
        p.mediaStopped()
        p.sync()
        let after = try #require(p.renderOffline(4096))
        #expect((0..<Int(after.frameLength)).allSatisfy { after.floatChannelData![0][$0] == 0 })
    }

    @Test func persistentlyUndecodableAudioFailsLocallyAndTerminationIsFinal() throws {
        let (p, states) = make()
        p.authorize(Self.authorization())
        p.sync()
        for i in 0..<AudioPipeline.decodeFailureLimit + 5 {
            _ = p.accept(packet(UInt16(i), arrival: UInt64(i) * 10 * ms, payload: [UInt8](repeating: 0xA5, count: 200)))
            if i % 16 == 15 { p.sync() } // keep this decoder test below the ingress limit
        }
        p.sync()
        #expect(p.snapshot.counters.decodeErrors >= AudioPipeline.decodeFailureLimit && !p.snapshot.running)
        guard case .failed = states.all.last else { Issue.record("expected failed, got \(String(describing: states.all.last))"); return }
        p.terminate()
        p.terminate()                                                       // idempotent
        p.authorize(Self.authorization())
        p.resume()
        p.setEnabled(true)
        p.sync()
        #expect(!p.snapshot.running && !p.accept(packet(1)))
    }

    /// A batch that first stops playback (here: the decode failure limit) and
    /// then releases held, decodable audio must not leave that audio queued for
    /// the next start: after Resume nothing plays until new packets arrive.
    @Test func audioReleasedAfterAFailureInTheSameBatchIsNeverPlayedLater() throws {
        let (p, states) = make()
        defer { p.terminate() }
        p.authorize(Self.authorization())
        p.sync()
        let limit = AudioPipeline.decodeFailureLimit
        for i in 0..<(limit - 1) {                                          // one short of the limit
            _ = p.accept(packet(UInt16(i), arrival: UInt64(i) * 10 * ms, payload: [UInt8](repeating: 0xA5, count: 200)))
            if i % 16 == 15 { p.sync() }
        }
        p.sync()
        let missing = UInt16(limit - 1)
        for k in 1...8 {                                                    // decodable audio held behind the gap
            _ = p.accept(packet(missing + UInt16(k), arrival: 1_000 * ms, payload: AudioFixture.accessUnits[2 + k]))
        }
        _ = p.accept(packet(missing, arrival: 1_001 * ms, payload: [UInt8](repeating: 0xA5, count: 200)))
        p.sync()
        guard case .failed = states.all.last else { Issue.record("expected failed, got \(String(describing: states.all.last))"); return }
        p.resume()
        p.sync()
        #expect(p.snapshot.running)
        let out = try #require(p.renderOffline(4096))                       // nothing new arrived since Resume
        #expect((0..<Int(out.frameLength)).allSatisfy { out.floatChannelData![0][$0] == 0 })
    }

    /// Consecutive sessions share the process's audio session: an earlier
    /// pipeline's late stop does not deactivate the one that activated it since.
    @Test func onlyTheLastActivatorDeactivatesTheSharedAudioSession() throws {
        let session = FakeAudioSession()
        let (old, _) = make(session: session), (new, _) = make(session: session)
        defer { old.terminate(); new.terminate() }
        old.authorize(Self.authorization())
        old.sync()
        new.authorize(Self.authorization())
        new.sync()
        old.terminate()
        old.sync()
        #expect(session.deactivations.load(ordering: .relaxed) == 0 && new.snapshot.running)
        new.revoke()
        new.sync()
        #expect(session.deactivations.load(ordering: .relaxed) == 1 && session.activations.load(ordering: .relaxed) == 2)
    }

    @Test func aDeviceThatCannotDecodeReportsUnavailable() {
        let p = AudioPipeline(session: FakeAudioSession(), output: .offline,
                              makeDecoder: { throw AACELDDecoder.Failure.unsupported })
        defer { p.terminate() }
        let states = Recorder<AudioPipeline.State>()
        p.bind { states.add($0) }
        p.authorize(Self.authorization())
        p.sync()
        #expect(!p.canPlay && states.all.last == .unavailable && !p.snapshot.running)
    }

    /// `.engineConfigurationChanged` events delivered
    /// while stopped during `.routeLost` must invalidate the cached AVAudioEngine
    /// graph without auto-resuming, so the first explicit `resume()` rebuilds a
    /// fresh graph cleanly with zero stale PCM replay.
    @Test func engineConfigurationChangedWhileRouteLostRebuildsGraphOnFirstResumeWithoutAutoResume() throws {
        let session = FakeAudioSession(outputRouteIDs: ["Headphones"])
        let (p, states) = make(session: session)
        defer { p.terminate() }
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization())
        p.sync()
        for seq: UInt16 in 1...4 {
            #expect(p.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            p.sync()
        }
        let initialEngine = try #require(p.offlineEngine)

        // Unplug headphones: stop immediately, keep routeLost sticky, reject packets.
        p.enqueueSystemEvent(.routeLost)
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.playing && !p.snapshot.accepting)
        #expect(p.state == .interrupted(.routeLost) && states.all.last == .interrupted(.routeLost))
        #expect(session.activations.load(ordering: .relaxed) == 1 && session.deactivations.load(ordering: .relaxed) == 1)
        #expect(!p.accept(packet(5, arrival: 50 * ms, payload: AudioFixture.accessUnits[4])))

        // Configuration changes and headphone reconnect while stopped must neither
        // auto-resume nor reactivate the session.
        session.setRoute(latency: 0.015, routeIDs: ["Speaker"])
        p.enqueueSystemEvent(.engineConfigurationChanged)
        session.setRoute(latency: 0.001, routeIDs: ["Headphones"])
        p.enqueueSystemEvent(.routeChanged)
        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.sync()
        let paused = p.snapshot
        #expect(!paused.running && !paused.playing && !paused.accepting)
        #expect(p.state == .interrupted(.routeLost))
        #expect(paused.counters.configurationChanges == 3)
        #expect(session.activations.load(ordering: .relaxed) == 1 && session.deactivations.load(ordering: .relaxed) == 1)
        #expect(!p.accept(packet(6, arrival: 60 * ms, payload: AudioFixture.accessUnits[5])))
        #expect(p.ingressReservations == (0, 0))

        // First explicit Resume Audio rebuilds a fresh graph and recovers without stale PCM.
        p.resume()
        p.sync()
        let resumed = p.snapshot
        #expect(resumed.running && resumed.playing && resumed.accepting)
        #expect(resumed.counters.starts == 2 && session.activations.load(ordering: .relaxed) == 2)
        if case .failed = p.state { Issue.record("first resume must not fail after stopped config changes") }
        let rebuiltEngine = try #require(p.offlineEngine)
        #expect(rebuiltEngine !== initialEngine)
        #expect(nonSilentFrames(try #require(p.renderOffline(4096))) == 0)

        let left = play(p, from: 100, count: 16)
        #expect(power(left[2400...], 1000) > 1e-3)
        #expect(p.state == .playing)
    }

    /// Overlapping `.interruptionBegan` → `.routeLost`
    /// → configuration changes → `.interruptionEnded(shouldResume: true)` must not
    /// auto-resume onto built-in speaker, and the first explicit `resume()` must
    /// rebuild the graph cleanly with zero stale PCM.
    @Test func overlappedInterruptionRouteLostAndConfigChangesRecoverOnFirstExplicitResume() throws {
        let session = FakeAudioSession(outputRouteIDs: ["Headphones"])
        let (p, _) = make(session: session)
        defer { p.terminate() }
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization())
        p.sync()
        for seq: UInt16 in 1...4 {
            #expect(p.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            p.sync()
        }
        let initialEngine = try #require(p.offlineEngine)

        p.enqueueSystemEvent(.interruptionBegan)
        p.sync()
        #expect(!p.snapshot.running && p.state == .interrupted(.system))

        session.setRoute(latency: 0.015, routeIDs: ["Speaker"])
        p.enqueueSystemEvent(.routeLost)
        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting && p.state == .interrupted(.routeLost))
        #expect(session.activations.load(ordering: .relaxed) == 1)
        #expect(!p.accept(packet(5, arrival: 50 * ms, payload: AudioFixture.accessUnits[4])))

        session.setRoute(latency: 0.001, routeIDs: ["Headphones"])
        p.enqueueSystemEvent(.routeChanged)
        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting && p.state == .interrupted(.routeLost))
        #expect(p.snapshot.counters.configurationChanges == 2 && session.activations.load(ordering: .relaxed) == 1)

        p.resume()
        p.sync()
        #expect(p.snapshot.running && p.snapshot.accepting && p.snapshot.counters.starts == 2)
        #expect(session.activations.load(ordering: .relaxed) == 2)
        let rebuiltEngine = try #require(p.offlineEngine)
        #expect(rebuiltEngine !== initialEngine)
        #expect(nonSilentFrames(try #require(p.renderOffline(4096))) == 0)

        let left = play(p, from: 200, count: 16)
        #expect(power(left[2400...], 1000) > 1e-3)
        #expect(p.state == .playing)
    }

    private enum StoppedConfigChangeState: CaseIterable, Sendable {
        case systemInterruption, disabled, revoked
    }

    @Test(arguments: StoppedConfigChangeState.allCases)
    private func engineConfigurationChangedWhileStoppedInvalidatesGraphForNextStart(
        _ stoppedState: StoppedConfigChangeState
    ) throws {
        let session = FakeAudioSession(outputRouteIDs: ["Speaker"])
        let (p, _) = make(session: session)
        defer { p.terminate() }
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization())
        p.sync()
        for seq: UInt16 in 1...4 {
            #expect(p.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            p.sync()
        }
        let initialEngine = try #require(p.offlineEngine)

        switch stoppedState {
        case .systemInterruption: p.enqueueSystemEvent(.interruptionBegan)
        case .disabled: p.setEnabled(false)
        case .revoked: p.revoke()
        }
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting)

        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.sync()
        #expect(!p.snapshot.running && !p.snapshot.accepting)
        #expect(p.snapshot.counters.configurationChanges == 1 && session.activations.load(ordering: .relaxed) == 1)

        switch stoppedState {
        case .systemInterruption: p.enqueueSystemEvent(.interruptionEnded(shouldResume: true))
        case .disabled: p.setEnabled(true)
        case .revoked: p.authorize(Self.authorization())
        }
        p.sync()
        #expect(p.snapshot.running && p.snapshot.accepting && p.snapshot.counters.starts == 2)
        let rebuiltEngine = try #require(p.offlineEngine)
        #expect(rebuiltEngine !== initialEngine)
        #expect(nonSilentFrames(try #require(p.renderOffline(4096))) == 0)
    }

    @Test func routeLostWithoutConfigChangeAndStoppedRouteChangeRebuildGraphSafely() async throws {
        let session = FakeAudioSession(outputRouteIDs: ["Headphones"])
        let (p, _) = make(session: session)
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization())
        p.sync()
        let firstEngine = try #require(p.offlineEngine)

        // Route lost without an engineConfigurationChanged still rebuilds on resume.
        p.enqueueSystemEvent(.routeLost)
        p.sync()
        #expect(!p.snapshot.running && p.state == .interrupted(.routeLost))
        p.resume()
        p.sync()
        let secondEngine = try #require(p.offlineEngine)
        #expect(secondEngine !== firstEngine)

        // Route change to a different route while stopped also invalidates the cached graph.
        p.setEnabled(false)
        p.sync()
        session.setRoute(latency: 0.015, routeIDs: ["Speaker"])
        p.enqueueSystemEvent(.routeChanged)
        p.sync()
        #expect(!p.snapshot.running && p.state == .disabled)
        p.setEnabled(true)
        p.sync()
        let thirdEngine = try #require(p.offlineEngine)
        #expect(thirdEngine !== secondEngine)

        // Invalidation while stopped followed by direct teardown drains cleanly.
        p.enqueueSystemEvent(.routeLost)
        p.enqueueSystemEvent(.engineConfigurationChanged)
        await p.stopAndDrain()
        #expect(!p.snapshot.running && !p.snapshot.accepting && p.ingressReservations == (0, 0))
    }

    @Test func engineConfigurationChangedWhileRunningRebuildsGraphWithoutDeactivatingSession() throws {
        let session = FakeAudioSession(outputRouteIDs: ["Speaker"])
        let (p, _) = make(session: session)
        defer { p.terminate() }
        p.mediaGenerationChanged(1)
        p.authorize(Self.authorization())
        p.sync()
        for seq: UInt16 in 1...4 {
            #expect(p.accept(packet(seq, arrival: UInt64(seq) * 10 * ms, payload: AudioFixture.accessUnits[Int(seq - 1)])))
            p.sync()
        }
        let initialEngine = try #require(p.offlineEngine)

        session.setRoute(latency: 0.001, routeIDs: ["Headphones"])
        p.enqueueSystemEvent(.engineConfigurationChanged)
        p.sync()
        let s = p.snapshot
        #expect(s.running && s.playing && s.accepting)
        #expect(s.counters.starts == 2 && s.counters.configurationChanges == 1)
        #expect(session.activations.load(ordering: .relaxed) == 1 && session.deactivations.load(ordering: .relaxed) == 0)
        let rebuiltEngine = try #require(p.offlineEngine)
        #expect(rebuiltEngine !== initialEngine)
        #expect(nonSilentFrames(try #require(p.renderOffline(4096))) == 0)

        let left = play(p, from: 20, count: 16)
        #expect(power(left[2400...], 1000) > 1e-3)
    }

    @Test func sessionEventsAreParsedFromTheSystemNotifications() {
        func note(_ name: Notification.Name, _ info: [AnyHashable: Any]) -> Notification { Notification(name: name, object: nil, userInfo: info) }
        #expect(AudioSessionEvent(note(AVAudioSession.routeChangeNotification,
                                       [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])) == .routeLost)
        #expect(AudioSessionEvent(note(AVAudioSession.routeChangeNotification,
                                       [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])) == .routeChanged)
        #expect(AudioSessionEvent(note(AVAudioSession.mediaServicesWereResetNotification, [:])) == .mediaServicesReset)
        #expect(AudioSessionEvent(note(AVAudioSession.mediaServicesWereLostNotification, [:])) == .mediaServicesLost)
        #expect(AudioSessionEvent(note(AVAudioSession.didBecomeInactiveNotification, [:])) == nil)    // no context: ours
        #expect(AudioSessionEvent(note(.init("unrelated"), [:])) == nil)
    }
}
