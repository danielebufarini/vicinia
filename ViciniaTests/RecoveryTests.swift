// Vicinia tests — bounded media recovery: recovery-request
// retry and its bound, decoder rebuild on persistent failure, media-stall
// detection. Injected time, no network.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import VideoToolbox
@testable import Vicinia

@Suite("Media recovery", .serialized)
struct RecoveryTests {
    private let ms: UInt64 = 1_000_000

    @Test func recoveryRequestIsRepeatedAtABoundedRateThenGivenUpOnce() {
        var retry = RecoveryRetry()
        #expect(retry.poll(now: 0) == .none)                                   // nothing is awaited
        retry.begin(now: 1_000 * ms)                                           // the loss made the first request
        #expect(retry.poll(now: 1_500 * ms) == .none)
        #expect(retry.poll(now: 1_600 * ms) == .request)
        #expect(retry.poll(now: 1_700 * ms) == .none)
        retry.begin(now: 2_000 * ms)                                           // another loss: also a request, same bound
        #expect(retry.poll(now: 2_500 * ms) == .none)
        #expect(retry.poll(now: 2_600 * ms) == .request)
        #expect(retry.poll(now: 6_999 * ms) == .request)
        #expect(retry.poll(now: 7_000 * ms) == .giveUp)                        // 6 s after the FIRST loss
        #expect(retry.poll(now: 9_000 * ms) == .none)                          // reported once, no loop
    }

    @Test func recoveryEndsWhenARandomAccessPointIsAccepted() {
        var retry = RecoveryRetry()
        #expect(retry.end(now: 5) == nil)
        retry.begin(now: 1_000 * ms)
        #expect(retry.end(now: 1_450 * ms) == 450 * ms)
        #expect(retry.poll(now: 60_000 * ms) == .none)
    }

    /// Through the pipeline: a lost picture is requested once at once, again
    /// while no random-access picture arrives, and ends in one readable failure.
    @Test func pipelineRetriesRecoveryAndFailsReadablyAtTheBound() {
        let pipeline = MediaPipeline(ssrcToStripe: [0x10: 0], canvas: (64, 16), ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let requests = Recorder<Int>(), failures = Recorder<String>()
        func rtp(_ seq: UInt16, _ marker: Bool, _ fu: UInt8) -> Data {
            var w = ByteWriter()
            w.u8(0x80); w.u8((marker ? 0x80 : 0) | 100); w.u16(seq); w.u32(4000); w.u32(0x10)
            w.append([0x62, 0x01, fu | 1, 0x00, 0x03] + [UInt8](repeating: 7, count: 20))
            return Data(w.bytes)
        }
        let c = pipeline.queue.sync {
            pipeline.onRecoveryNeeded = { requests.add($0) }
            pipeline.onFailure = { failures.add($0) }
            pipeline.ingest(rtp(1, false, 0x80), arrival: 0)
            pipeline.ingest(rtp(3, true, 0x40), arrival: 0)                    // sequence 2 never arrives
            pipeline.poll(now: 30 * ms)                                        // gap expired: loss, first request
            #expect(requests.all == [0])
            pipeline.poll(now: 400 * ms)
            #expect(requests.all == [0])
            for t in stride(from: UInt64(700), through: 5_900, by: 100) { pipeline.poll(now: t * ms) }
            #expect(failures.all.isEmpty)
            pipeline.poll(now: 6_100 * ms)
            pipeline.poll(now: 9_000 * ms)
            return pipeline.counters.snapshot
        }
        #expect(c.recoveryRequests == 1 && c.recoveryRetries == requests.all.count - 1)
        #expect((7...9).contains(c.recoveryRetries))                           // every 0.6 s for < 6 s
        #expect(failures.all.count == 1 && c.recoveryGiveUps == 1)
        #expect(failures.all.first?.contains("no random-access picture") == true)
        // A new stream (resize, new offer) owes nothing to the old loss.
        let later = pipeline.queue.sync {
            pipeline.resetStream()
            pipeline.poll(now: 20_000 * ms)
            return (requests.all.count, failures.all.count)
        }
        #expect(later == (requests.all.count, 1))
    }

    @Test func decoderIsRebuiltOnlyWhenARandomAccessPictureCannotRepairIt() {
        var policy = DecoderRebuildPolicy()
        // An ordinary failed picture: keep the session, re-root at the next random-access picture.
        #expect(policy.onFailure(status: kVTVideoDecoderBadDataErr, wasRandomAccess: false, now: 0) == .awaitRandomAccess)
        // The session was invalidated by the system (e.g. app in the background), or the
        // random-access picture itself failed: rebuild from the retained parameter sets.
        #expect(policy.onFailure(status: kVTInvalidSessionErr, wasRandomAccess: false, now: 1_000 * ms) == .rebuild)
        #expect(policy.onFailure(status: kVTVideoDecoderBadDataErr, wasRandomAccess: true, now: 2_000 * ms) == .rebuild)
        #expect(policy.onFailure(status: kVTInvalidSessionErr, wasRandomAccess: true, now: 3_000 * ms) == .rebuild)
        // Bounded: a fourth rebuild inside 10 s is refused (readable failure), never a loop.
        #expect(policy.onFailure(status: kVTInvalidSessionErr, wasRandomAccess: false, now: 4_000 * ms) == .giveUp)
        #expect(policy.onFailure(status: kVTVideoDecoderBadDataErr, wasRandomAccess: false, now: 4_100 * ms) == .awaitRandomAccess)
        // Outside the window the budget is available again.
        #expect(policy.onFailure(status: kVTInvalidSessionErr, wasRandomAccess: false, now: 14_000 * ms) == .rebuild)
    }

    /// Silence on the media legs is shown, clears when authenticated media
    /// returns, and ends in exactly one bounded loss report. Unauthenticated
    /// datagrams are not liveness; a suspended process is not a host stall.
    @Test func mediaStallIsReportedClearedAndBounded() throws {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let events = Recorder<MediaLiveness>()
        let half = 500 * ms
        try pipeline.queue.sync {
            defer { transport.stop(); pipeline.resetStream() }
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onLiveness = { events.add($0) }
            let host = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
            let t0: UInt64 = 100_000 * ms
            transport.checkLiveness(now: t0)                                    // first check starts the clock
            transport.checkLiveness(now: t0 + half)
            transport.checkLiveness(now: t0 + 2 * half)
            #expect(events.all.isEmpty)
            transport.ingestVideo(Data([UInt8](repeating: 0x80, count: 40)), now: t0 + 2 * half + 1)   // not authentic
            transport.checkLiveness(now: t0 + 3 * half)
            transport.checkLiveness(now: t0 + 4 * half)
            #expect(events.all == [.stalled(seconds: 1.5), .stalled(seconds: 2.0)])
            #expect(transport.counters.srtcpFailures + transport.counters.srtpAuthFailures + transport.counters.srtpOtherErrors == 1)
            // An authenticated host report: media is flowing again.
            let report = RTCPBuild.rr(sender: 0x5150, sources: [])
            transport.ingestVideo(try host.protectRTCP(report), now: t0 + 4 * half + 100 * ms)
            transport.checkLiveness(now: t0 + 5 * half)
            #expect(events.all.last == .resumed)
            #expect(transport.counters.longestSilenceNanos == 4 * half + 100 * ms)
            // Then nothing at all: shown from 1.5 s, one loss report at the 10 s bound.
            let silentFrom = t0 + 4 * half + 100 * ms
            var t = t0 + 5 * half
            while t < silentFrom + 12_000 * ms { t += half; transport.checkLiveness(now: t) }
            let lost = events.all.filter { if case .lost = $0 { true } else { false } }
            #expect(lost.count == 1)
            if case .lost(let seconds)? = lost.first { #expect(seconds >= 10 && seconds < 10.5) }
            #expect(transport.counters.mediaStalls == 2)
            // The process was suspended (a check 30 s late): not a host stall — the clock restarts.
            let before = events.all.count
            transport.ingestVideo(try host.protectRTCP(report), now: t + 1)
            transport.checkLiveness(now: t + half)
            let resumedAt = events.all.count
            transport.checkLiveness(now: t + half + 30_000 * ms)
            transport.checkLiveness(now: t + 2 * half + 30_000 * ms)
            #expect(events.all.count == resumedAt && resumedAt == before + 1)   // only the `.resumed`
        }
    }

    /// Transport liveness is the media PATH, not the picture: host reports on
    /// the video leg alone keep it alive. With no coded picture arriving there
    /// is nothing owed either (a static desktop), so nothing is indicated or
    /// failed. Video progress is judged separately: see the next test.
    @Test func hostReportsAloneKeepThePathAliveWithoutAnyVideo() throws {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let events = Recorder<MediaLiveness>()
        try pipeline.queue.sync {
            defer { transport.stop(); pipeline.resetStream() }
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onLiveness = { events.add($0) }
            let host = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
            var t: UInt64 = 100_000 * ms
            transport.checkLiveness(now: t)
            for second in 0..<30 {                                              // 30 s: one report a second, no RTP at all
                if second > 0 { transport.ingestVideo(try host.protectRTCP(RTCPBuild.rr(sender: 0x5150, sources: [])), now: t) }
                for _ in 0..<2 { t += 500 * ms; transport.checkLiveness(now: t) }
            }
            #expect(events.all.isEmpty)
            #expect(transport.counters.mediaStalls == 0 && transport.counters.rtcpIn == 29)
        }
    }

    /// Video progress, not traffic: pictures that keep arriving without any
    /// presentation are a stall however much authenticated RTCP/audio flows; a
    /// static desktop, an inactive display and a stray unshown picture are not.
    @Test func arrivingPicturesWithoutPresentationAreAStallButAStaticDesktopIsNot() {
        let s = 1_000 * ms
        var floor: UInt64 = 100 * s
        /// `run`: when the current run of pictures began (here: one unbroken run since 101 s unless stated).
        func unshown(picture: UInt64, run: UInt64 = 101_000 * 1_000_000, presented: UInt64, active: Bool = true, now: UInt64) -> UInt64 {
            MediaTransport.unshownNanos(pictures: (picture, run), progress: (presented, active), floor: &floor, now: now)
        }
        // Static desktop: the last picture was presented, nothing arrives for a minute.
        #expect(unshown(picture: 101 * s, presented: 101 * s + 20 * ms, now: 161 * s) == 0)
        // One picture after the last presentation that is never shown (late/superseded), then nothing: it does not grow.
        #expect(unshown(picture: 102 * s, presented: 101 * s + 20 * ms, now: 200 * s) == s - 20 * ms)
        // Pictures keep arriving, nothing presented since 101.02 s: indicator, then the bound.
        #expect(unshown(picture: 103 * s, presented: 101 * s + 20 * ms, now: 103 * s) >= MediaTransport.stallIndicatorNanos)
        #expect(unshown(picture: 112 * s, presented: 101 * s + 20 * ms, now: 112 * s) >= MediaTransport.stallLimitNanos)
        // A presentation settles it.
        #expect(unshown(picture: 112 * s, presented: 112 * s + 20 * ms, now: 113 * s) == 0)
        // Display not active (app inactive/backgrounded): nothing is owed, and the clock restarts afterwards.
        #expect(unshown(picture: 130 * s, presented: 112 * s + 20 * ms, active: false, now: 130 * s) == 0)
        #expect(unshown(picture: 131 * s, presented: 112 * s + 20 * ms, now: 131 * s) == s)
        // A minute of static desktop, then a picture that starts a new run, checked before it is shown: the idle
        // minute is not counted. If that run then stays unshown it is timed from its own onset.
        #expect(unshown(picture: 191 * s, run: 191 * s, presented: 131 * s + 20 * ms, now: 191 * s + 100 * ms) == 0)
        #expect(unshown(picture: 193 * s, run: 191 * s, presented: 131 * s + 20 * ms, now: 193 * s) == 2 * s)
        #expect(unshown(picture: 201 * s, run: 191 * s, presented: 131 * s + 20 * ms, now: 201 * s) == MediaTransport.stallLimitNanos)

        // The pipeline starts a new run only after `stallIndicatorNanos` without a picture.
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: EvidenceLog())
        let runs: [UInt64] = pipeline.queue.sync {
            [10 * s, 10 * s + 16 * ms, 11 * s + 500 * ms, 13 * s, 13 * s + 16 * ms].map {
                pipeline.notePicture(now: $0)
                return pipeline.pictureRunNanos
            }
        }
        #expect(runs == [10 * s, 10 * s, 10 * s, 13 * s, 13 * s])

        // The display side reports progress only for an actual presentation.
        let mailbox = DesktopUpdateMailbox()
        #expect(mailbox.presentationProgress.last == 0 && mailbox.presentationProgress.displayActive)
        mailbox.note(UpdateRecord(), .noPresentedTime)
        mailbox.note(UpdateRecord(), .supersededInMailbox)
        #expect(mailbox.presentationProgress.last == 0)
        mailbox.note(UpdateRecord(), .presented)
        #expect(mailbox.presentationProgress.last > 0)
        mailbox.setDisplayActive(false)
        #expect(!mailbox.presentationProgress.displayActive)
    }

    /// Through the transport: authenticated reports keep arriving every second
    /// while pictures arrive and nothing is presented — shown from 1.5 s, one
    /// bounded failure at 10 s (`unshown`, not `lost`).
    @Test func transportReportsUnshownPicturesDespiteLiveReports() throws {
        let evidence = EvidenceLog()
        let mailbox = DesktopUpdateMailbox()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: mailbox, evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let events = Recorder<MediaLiveness>()
        try pipeline.queue.sync {
            defer { transport.stop(); pipeline.resetStream() }
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onLiveness = { events.add($0) }
            let host = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
            var t: UInt64 = 100_000 * ms
            transport.checkLiveness(now: t)
            for _ in 0..<24 {                                                   // 12 s
                t += 500 * ms
                transport.ingestVideo(try host.protectRTCP(RTCPBuild.rr(sender: 0x5150, sources: [])), now: t)
                pipeline.notePicture(now: t)                                    // a coded picture arrived; none is presented
                transport.checkLiveness(now: t)
            }
            let stalls = events.all.filter { if case .stalled = $0 { true } else { false } }
            let unshown = events.all.filter { if case .unshown = $0 { true } else { false } }
            #expect(stalls.first == .stalled(seconds: 1.5) && unshown.count == 1)
            #expect(!events.all.contains { if case .lost = $0 { true } else { false } })
            if case .unshown(let seconds)? = unshown.first { #expect(seconds >= 10 && seconds < 10.5) }
        }
    }

    /// A desktop that was legitimately static for longer than the failure
    /// bound owes nothing for that time. The first picture after it arrives and
    /// the check runs before it could be presented: no indicator, no failure.
    /// Outstanding video work is counted from that picture on — and still
    /// ends in the indicator and exactly one bounded failure if pictures then
    /// keep arriving and none is ever shown.
    @Test func pictureAfterALongStaticDesktopIsNotAStallUntilItStaysUnshown() throws {
        let evidence = EvidenceLog()
        let mailbox = DesktopUpdateMailbox()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: mailbox, evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let offer = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let events = Recorder<MediaLiveness>()
        let half = 500 * ms
        try pipeline.queue.sync {
            defer { transport.stop(); pipeline.resetStream() }
            try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: 1)
            transport.onLiveness = { events.add($0) }
            let host = try SRTPSession(keySalt: offer.keys.videoFromHost, inbound: false)
            func report(_ now: UInt64) throws {
                transport.ingestVideo(try host.protectRTCP(RTCPBuild.rr(sender: 0x5150, sources: [])), now: now)
            }
            // The mailbox stamps a presentation with the real clock: the scenario is laid out after it.
            let t0 = DispatchTime.now().uptimeNanoseconds + 1_000 * ms
            pipeline.notePicture(now: t0 - 1_050 * ms)
            mailbox.note(UpdateRecord(), .presented)                            // the last picture was shown (before t0)
            transport.checkLiveness(now: t0)
            var t = t0
            while t < t0 + 15_000 * ms {                                        // 15 s static: reports only, no picture
                t += half
                try report(t)
                transport.checkLiveness(now: t)
            }
            #expect(events.all.isEmpty)
            // The desktop changes: one coded picture arrives; the check runs 100 ms later, before any presentation.
            pipeline.notePicture(now: t + 400 * ms)
            t += half
            try report(t)
            transport.checkLiveness(now: t)
            #expect(events.all.isEmpty)                                         // 15 s of idle time are not a stall
            // From here on pictures keep arriving and none is presented: that IS a stall, timed from its onset.
            let onset = t - 100 * ms
            while t < onset + 13_000 * ms {
                t += half
                try report(t)
                pipeline.notePicture(now: t - 100 * ms)
                transport.checkLiveness(now: t)
            }
            let stalls = events.all.filter { if case .stalled = $0 { true } else { false } }
            let unshown = events.all.filter { if case .unshown = $0 { true } else { false } }
            #expect(stalls.first == .stalled(seconds: 1.5))
            #expect(unshown.count == 1)                                         // one failure notification, not one per check
            if case .unshown(let seconds)? = unshown.first { #expect(seconds >= 10 && seconds < 10.5) }
            #expect(!events.all.contains { if case .lost = $0 { true } else { false } })
            #expect(transport.counters.longestUnshownNanos < 13_500 * ms)       // the idle 15 s were never counted
        }
    }
}
