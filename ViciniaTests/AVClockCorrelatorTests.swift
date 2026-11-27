// Vicinia — deterministic HPSS sender clocks and local presentation.
// SPDX-License-Identifier: MIT

import Testing
@testable import Vicinia

@Suite("Common HPSS audio/video clock")
struct AVClockCorrelatorTests {
    private struct Rig {
        static let audio: UInt32 = 11, video: UInt32 = 22
        let clock = AVClockCorrelator()
        var offer: UInt64 = 1
        var ntp: UInt32 = 4_004_090_000
        var a: UInt32 = 0x4990_0000, v: UInt32 = 0x0000_5BA0

        init() { setup() }

        func setup() {
            clock.configure(offer: offer)
            clock.selectSource(.audio, ssrc: Self.audio, offer: offer)
            clock.selectSource(.video, ssrc: Self.video, offer: offer)
        }

        func local(_ seconds: Double) -> UInt64 { UInt64(((20 + seconds) * 1e9).rounded()) }
        func audioRTP(_ seconds: Double) -> UInt32 { a &+ UInt32((48_000 * seconds).rounded()) }
        func videoRTP(_ seconds: Double) -> UInt32 { v &+ UInt32((24_000 * seconds).rounded()) }

        func report(_ leg: AVClockCorrelator.Leg, at time: Double, source: UInt32? = nil,
                    seconds: UInt32? = nil, timestamp: UInt32? = nil, arrival: Double? = nil) {
            let whole = UInt32(time)
            let fraction = UInt32((time - Double(whole)) * 4_294_967_296)
            let ssrc = source ?? (leg == .audio ? Self.audio : Self.video)
            clock.senderReport(.init(ssrc: ssrc, ntpSeconds: seconds ?? (ntp &+ whole), ntpFraction: fraction,
                                     rtpTimestamp: timestamp ?? (leg == .audio ? audioRTP(time) : videoRTP(time))),
                               leg: leg, offer: offer, received: local(arrival ?? (time + 0.010)))
        }

        func anchors(at t: Double = 0) {
            for step in [t, t + 1] {
                report(.audio, at: step + 0.125)
                report(.video, at: step + 0.250)
            }
        }

        func present(_ time: Double, delay: Double = 0.060, timestamp: UInt32? = nil) {
            clock.videoPresented(offer: offer, generation: 0, timestamp: timestamp ?? videoRTP(time), nanos: local(time + delay))
        }

        // A 960-sample scheduled distance (20 ms) plus 10 ms of route latency
        // projects a render at +30 ms onto the matching +60 ms video present.
        func error(_ time: Double, latency: Double = 0.010, timestamp: UInt32? = nil,
                   renderTime: Double? = nil, source: UInt32 = Rig.audio, decision: Double? = nil) -> Double? {
            clock.audioErrorFrames(offer: offer, ssrc: source, timestamp: timestamp ?? audioRTP(time),
                                   now: local(decision ?? (time + 0.060)), renderHostNanos: local(renderTime ?? (time + 0.030)),
                                   playerSample: -2048, startSample: -1088, outputLatency: latency)
        }
    }

    @Test func independentOriginsAndSenderReportPhasesMapToOneTimebase() throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.5)
        #expect(abs(try #require(rig.error(1.5))) < 0.001)
        rig.clock.resetAudioProjection(offer: rig.offer)
        rig.present(1.75)
        #expect(abs(try #require(rig.error(1.75, latency: 0.050)) - 1920) < 0.001)
    }

    @Test func eachRTPClockAndTheNTPClockCanCrossTheirOwnWrap() throws {
        var rig = Rig()
        rig.ntp = .max
        rig.a = .max - 84_999
        rig.v = .max - 42_499
        rig.anchors()
        // Project a frame on each side of both RTP wraps, with reports
        // spanning the NTP seconds rollover (nonzero fractional words).
        rig.present(1.5)
        #expect(abs(try #require(rig.error(1.5))) < 0.001)
        rig.present(2.0)
        #expect(abs(try #require(rig.error(2.0))) < 0.001)
        rig.report(.audio, at: 2.125)
        rig.report(.video, at: 2.250)
        rig.present(2.5)
        #expect(abs(try #require(rig.error(2.5))) < 0.001)
    }

    @Test func missingStaleAndMalformedClocksLeaveOccupancyInControl() throws {
        let rig = Rig()
        rig.report(.audio, at: 0.125)
        rig.report(.audio, at: 1.125)
        rig.present(1.5)
        #expect(rig.error(1.5) == nil)
        rig.report(.video, at: 0.250, seconds: 0)
        rig.report(.video, at: 1.250)
        rig.present(1.75)
        #expect(rig.error(1.75) == nil)
        rig.report(.video, at: 2.250)
        rig.present(2.5)
        #expect(abs(try #require(rig.error(2.5))) < 0.001)
        rig.present(20)
        #expect(rig.error(20) == nil)
        var playout = PlayoutControl()
        #expect(playout.decide(level: playout.targetFrames, avErrorFrames: rig.error(20)) == .play(adjust: 0))
    }

    @Test(arguments: [AVClockCorrelator.Leg.audio, .video])
    func selectedZeroSenderReportRequiresNewAnchors(_ leg: AVClockCorrelator.Leg) throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.5)
        #expect(rig.error(1.5, decision: 1.560) != nil)
        let selected = leg == .audio ? Rig.audio : Rig.video
        let phase: UInt32 = leg == .audio ? 1920 : 960
        func rtp(_ time: Double) -> UInt32 {
            (leg == .audio ? rig.audioRTP(time) : rig.videoRTP(time)) + phase
        }
        func zero(_ source: UInt32, time: Double) {
            rig.clock.senderReport(.init(ssrc: source, ntpSeconds: 0, ntpFraction: 0, rtpTimestamp: rtp(time)),
                                   leg: leg, offer: rig.offer, received: rig.local(time + 0.010))
        }
        zero(999, time: 1.6)
        rig.present(1.7)
        #expect(rig.error(1.7, decision: 1.760) != nil)

        zero(selected, time: 1.8)
        func sample(_ time: Double) -> Double? {
            rig.present(time, timestamp: leg == .video ? rtp(time) : nil)
            return rig.error(time, timestamp: leg == .audio ? rtp(time) : nil, decision: time + 0.060)
        }
        #expect(sample(1.9) == nil)
        var playout = PlayoutControl()
        #expect(playout.decide(level: playout.targetFrames, avErrorFrames: sample(2.0)) == .play(adjust: 0))
        rig.report(leg, at: 2.125, timestamp: rtp(2.125))
        #expect(sample(2.5) == nil)
        rig.report(leg, at: 3.125, timestamp: rtp(3.125))
        #expect(abs(try #require(sample(3.5))) < 0.001)
    }

    @Test func pastOutputEndpointFallsBackAndAForwardRenderPairRecovers() throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.25)
        #expect(abs(try #require(rig.error(1.5, decision: 1.545))) < 0.001)
        var playout = PlayoutControl()
        let stale = rig.error(1.75, latency: 0.050, renderTime: 1.5, decision: 1.765)
        #expect(stale == nil)
        #expect(playout.decide(level: playout.targetFrames, avErrorFrames: stale) == .play(adjust: 0))
        let valid = try #require(rig.error(2.0, renderTime: 2.030, decision: 2.015))
        #expect(abs(valid) < 0.001)
        #expect(playout.decide(level: playout.targetFrames, avErrorFrames: valid) == .play(adjust: 0))
    }

    @Test(arguments: [true, false])
    func latencyStepSeedsTheErrorForTheNewRoute(_ increase: Bool) throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.3, delay: 0.080)
        let firstLatency = increase ? 0.010 : 0.090
        let secondLatency = increase ? 0.090 : 0.010
        let first = try #require(rig.error(1.5, latency: firstLatency, renderTime: 1.510, decision: 1.515))
        #expect(abs(first - (increase ? -1920 : 1920)) < 0.001)
        let error = try #require(rig.error(1.75, latency: secondLatency, renderTime: 1.760, decision: 1.765))
        #expect(abs(error - (increase ? 1920 : -1920)) < 0.001, "error ms: \(error / 48)")
        var playout = PlayoutControl()
        #expect(playout.decide(level: playout.targetFrames + 240, avErrorFrames: error)
                == .play(adjust: increase ? -4 : 4))
        let stale = rig.error(2.0, latency: secondLatency, renderTime: 1.75, decision: 2.015)
        #expect(stale == nil)
        #expect(playout.decide(level: playout.targetFrames, avErrorFrames: stale) == .play(adjust: 0))
    }

    @Test func aNewRouteWithEqualLatencyWaitsForANewRenderPair() throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.3, delay: 0.080)
        let initial = try #require(rig.error(1.5, latency: 0.050, renderTime: 1.550, decision: 1.560))
        #expect(abs(initial - 1920) < 0.001)
        rig.clock.audioRouteChanged(offer: rig.offer, after: rig.local(1.750))
        rig.clock.audioRouteChanged(offer: rig.offer, after: rig.local(1.700)) // an earlier boundary cannot regress it
        // Even a still-forward predicted endpoint can be from the old route.
        #expect(rig.error(1.7, latency: 0.050, renderTime: 1.745, decision: 1.755) == nil)
        let fresh = try #require(rig.error(2.0, latency: 0.050, renderTime: 1.970, decision: 2.000))
        #expect(abs(fresh + 1920) < 0.001)
    }

    @Test func fractionalEraRolloverUsesTheRecentAnchorInALongSession() throws {
        var rig = Rig()
        rig.ntp = UInt32.max - 20
        rig.anchors()
        rig.anchors(at: 19)
        rig.report(.audio, at: 21.125)
        rig.report(.video, at: 21.250)
        rig.present(21.5)
        #expect(abs(try #require(rig.error(21.5))) < 0.001)
    }

    @Test func inconsistentRatesAndBackwardNTPInvalidateTheProjection() throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.5)
        #expect(rig.error(1.5) != nil)
        rig.report(.audio, at: 2.125, seconds: rig.ntp - 1)
        rig.present(2.5)
        #expect(rig.error(2.5) == nil)
        rig.report(.audio, at: 3.125, timestamp: rig.audioRTP(3.25)) // wrong clock rate
        rig.present(3.5)
        #expect(rig.error(3.5) == nil)
        rig.report(.audio, at: 4.125)
        rig.report(.audio, at: 5.125)
        rig.report(.video, at: 5.250)
        rig.present(5.5)
        #expect(abs(try #require(rig.error(5.5))) < 0.001)
    }

    @Test func differentSenderClockEpochsAndZeroDrawableTimeCannotSteer() {
        let rig = Rig()
        rig.report(.audio, at: 0.125)
        rig.report(.audio, at: 1.125)
        rig.report(.video, at: 0.250, seconds: rig.ntp + 3)
        rig.report(.video, at: 1.250, seconds: rig.ntp + 4)
        rig.clock.videoPresented(offer: rig.offer, generation: 0, timestamp: rig.videoRTP(1.5), nanos: 0)
        #expect(rig.error(1.5) == nil)
        rig.present(1.75)
        #expect(rig.error(1.75) == nil)
    }

    @Test func ssrcChangesAndSuspensionDiscardOldClockState() throws {
        var rig = Rig()
        rig.anchors()
        rig.present(1.5)
        #expect(rig.error(1.5) != nil)
        rig.clock.selectSource(.audio, ssrc: 99, offer: rig.offer)
        rig.present(1.75)
        #expect(rig.error(1.75) == nil && rig.error(1.75, source: 99) == nil)
        rig.report(.audio, at: 2.125, source: 99)
        rig.report(.audio, at: 3.125, source: 99)
        rig.report(.video, at: 3.25)
        rig.present(3.5)
        #expect(abs(try #require(rig.error(3.5, source: 99))) < 0.001)
        rig.clock.suspend(offer: rig.offer)
        rig.anchors(at: 4)
        rig.present(5.5)
        #expect(rig.error(5.5, source: 99) == nil)
        rig.offer += 1
        rig.setup()
        #expect(rig.error(5.5) == nil)
        rig.anchors(at: 6)
        rig.present(7.5)
        rig.clock.suspend(offer: 1) // late stop from a retired transport
        #expect(abs(try #require(rig.error(7.5))) < 0.001)
    }

    @Test func aPauseResetsPresentationAndAnRTPJumpRequiresNewReports() throws {
        let rig = Rig()
        rig.anchors()
        rig.present(1.5)
        #expect(rig.error(1.5) != nil)
        #expect(rig.error(4.5) == nil)
        rig.report(.audio, at: 4.125)
        rig.report(.video, at: 4.250)
        rig.present(4.5, delay: 0.080)
        #expect(abs(try #require(rig.error(4.5, latency: 0.030, decision: 4.580))) < 0.001)
        rig.present(4.75, delay: 0.080)
        let jump = rig.audioRTP(4.75) + 8 * 48_000
        #expect(rig.error(4.75, timestamp: jump) == nil)
        rig.report(.audio, at: 5.125, timestamp: rig.audioRTP(5.125) + 8 * 48_000)
        rig.report(.audio, at: 6.125, timestamp: rig.audioRTP(6.125) + 8 * 48_000)
        rig.report(.video, at: 6.250)
        rig.present(6.5)
        #expect(abs(try #require(rig.error(6.5, timestamp: rig.audioRTP(6.5) + 8 * 48_000))) < 0.001)
    }

    @Test(arguments: [-200.0, -50.0, 50.0, 200.0])
    func measuredClockAndBoundedPacingTrackSmallPersistentDrift(_ ppm: Double) throws {
        let rig = Rig()
        let drift = ppm / 1_000_000
        var correction = 0, playout = PlayoutControl()
        var valid = 0, worst = 0.0
        playout.noteArrival(sequence: 1, arrival: 0)
        playout.noteArrival(sequence: 2, arrival: 80_000_000) // measured headroom above the route floor
        for i in 0...8000 {
            let t = Double(i) / 100
            if i % 100 == 0 {
                rig.report(.video, at: t, arrival: t * (1 + drift) + 0.010)
                rig.report(.audio, at: t, arrival: t * (1 + drift) + 0.010)
            }
            let local = t * (1 + drift)
            if i >= 3 {
                let videoTime = Double(i - 3) / 100
                rig.clock.videoPresented(offer: rig.offer, generation: 0, timestamp: rig.videoRTP(videoTime),
                                         nanos: rig.local(videoTime * (1 + drift) + 0.060))
            }
            let error = rig.clock.audioErrorFrames(offer: rig.offer, ssrc: Rig.audio, timestamp: rig.audioRTP(t),
                                                   now: rig.local(local + 0.040),
                                                   renderHostNanos: rig.local(t + 0.030 + Double(correction) / 48_000),
                                                   playerSample: 0, startSample: 960, outputLatency: 0.010)
            guard let error else { continue }
            valid += 1
            worst = max(worst, abs(error))
            let occupancy = playout.targetFrames + correction - Int((t * drift * 48_000).rounded())
            if case .play(let adjustment) = playout.decide(level: occupancy, avErrorFrames: error) { correction += adjustment }
        }
        #expect(valid > 7500 && worst < 300)
        #expect(abs(correction) > 100)
        #expect(playout.targetFrames >= playout.minimumFrames && playout.targetFrames <= PlayoutControl.maximumTargetFrames)
    }
}
