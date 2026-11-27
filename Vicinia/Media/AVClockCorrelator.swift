// Vicinia — common HPSS sender clock. The renderer reports presents as they
// happen. Only audio pacing uses the measurement.
// SPDX-License-Identifier: MIT

import Synchronization

final class AVClockCorrelator: Sendable {
    enum Leg: String, Sendable { case audio, video }

    private static let reportMaxAge: UInt64 = 10_000_000_000
    private static let videoMaxAge: UInt64 = 2_000_000_000
    private static let maxReportSkew = 0.25 // receipt jitter and different SR phases
    // Ignore sub-millisecond jitter in the system's latency estimate.
    static let routeLatencyStep = 0.001

    private struct Anchor {
        let ntp: UInt64                       // unsigned NTP 32.32 on the wire
        let rtp: Int64                        // extended independently for each SSRC
        let received: UInt64                  // device monotonic nanoseconds
    }

    private struct Stream {
        let nominalRate: Double
        var ssrc: UInt32?
        var anchor: Anchor?
        var measuredRate: Double?             // usable after two mutually consistent SRs
        var lastSample: (rtp: Int64, nanos: UInt64)?

        mutating func setSource(_ source: UInt32) -> Bool {
            guard ssrc != source else { return false }
            self = Stream(nominalRate: nominalRate, ssrc: source)
            return true
        }

        mutating func report(ntp: UInt64, rtp: UInt32, received: UInt64) -> Bool {
            guard ntp != 0 else { anchorDiscontinuity(); return false }
            guard let previous = anchor else {
                anchor = Anchor(ntp: ntp, rtp: Int64(rtp), received: received)
                return false
            }
            guard received > previous.received else { measuredRate = nil; return false }
            let seconds = AVClockCorrelator.ntpSeconds(ntp, since: previous.ntp)
            guard seconds > 0 else { measuredRate = nil; return false }
            let elapsed = Double(received - previous.received) / 1e9
            let extended = Self.extend(rtp, near: previous.rtp)
            let rate = Double(extended - previous.rtp) / seconds
            anchor = Anchor(ntp: ntp, rtp: extended, received: received)
            guard received - previous.received <= AVClockCorrelator.reportMaxAge,
                  abs(elapsed - seconds) <= AVClockCorrelator.maxReportSkew,
                  (0.98 * nominalRate...1.02 * nominalRate).contains(rate) else {
                measuredRate = nil
                lastSample = nil
                return false
            }
            measuredRate = measuredRate.map { $0 + (rate - $0) / 8 } ?? rate
            return true
        }

        mutating func hostSeconds(rtp: UInt32, observed: UInt64, epoch: UInt64) -> Double? {
            guard let anchor, let rate = measuredRate,
                  AVClockCorrelator.fresh(anchor, at: observed) else { return nil }
            let extended = Self.extend(rtp, near: anchor.rtp)
            let fromAnchor = Double(extended - anchor.rtp) / rate
            if let last = lastSample {
                guard observed >= last.nanos else { return nil } // late drawable callback
                let elapsed = Double(observed - last.nanos) / 1e9
                let step = Double(extended - last.rtp) / rate
                if step < -0.25 || abs(step - elapsed) > 2 {
                    // A new RTP timeline needs fresh reports. Keep the SSRC.
                    anchorDiscontinuity()
                    return nil
                }
                guard extended > last.rtp else { return nil }
            }
            let transportOffset = AVClockCorrelator.localSeconds(observed, since: anchor.received) - fromAnchor
            guard abs(transportOffset) < 2 else { return nil }
            lastSample = (extended, observed)
            return AVClockCorrelator.ntpSeconds(anchor.ntp, since: epoch) + fromAnchor
        }

        private mutating func anchorDiscontinuity() {
            anchor = nil
            measuredRate = nil
            lastSample = nil
        }

        private static func extend(_ timestamp: UInt32, near previous: Int64) -> Int64 {
            previous + Int64(Int32(bitPattern: timestamp &- UInt32(truncatingIfNeeded: previous)))
        }
    }

    private struct State {
        var offer: UInt64?
        var active = false
        var epoch: Anchor?
        var audio = Stream(nominalRate: HPSSAudio.sampleRate)
        var video = Stream(nominalRate: RctlState.videoClockHz)
        var videoGeneration: UInt64 = 0
        var videoOffset: (seconds: Double, presented: UInt64)?
        var audioError: Double?
        var audioLatency: Double?
        var audioRouteBoundary: UInt64 = 0

        mutating func setSource(_ leg: Leg, ssrc: UInt32) {
            let changed: Bool
            switch leg {
            case .audio: changed = audio.setSource(ssrc)
            case .video: changed = video.setSource(ssrc)
            }
            if changed { videoOffset = nil; audioError = nil }
        }
    }

    // This lock only protects fixed-size scalar clock state. Its callbacks do
    // not call into the media, render or audio queues or their locks.
    private let state = Mutex(State())

    func configure(offer: UInt64) {
        state.withLock { state in
            if let previous = state.offer, offer <= previous { return }
            state = State(offer: offer, active: true)
        }
    }

    func suspend(offer: UInt64?) {
        state.withLock { state in
            guard state.offer == offer else { return }
            state = State(offer: offer)
        }
    }

    func selectSource(_ leg: Leg, ssrc: UInt32, offer: UInt64) {
        state.withLock { state in
            guard state.active, state.offer == offer else { return }
            state.setSource(leg, ssrc: ssrc)
        }
    }

    func senderReport(_ report: RTCPBuild.SenderReportClock, leg: Leg, offer: UInt64, received: UInt64) {
        state.withLock { state in
            guard state.active, state.offer == offer else { return }
            let stream = leg == .audio ? state.audio : state.video
            guard stream.ssrc == report.ssrc else { return }
            let ntp = report.ntp
            // A nonzero fraction in second zero is valid after a near-wrap
            // report. Use the selected leg's latest anchor across long sessions.
            let nearEraBoundary = (stream.anchor ?? state.epoch)
                .map { abs(Self.ntpSeconds(ntp, since: $0.ntp)) <= 10 } ?? false
            guard ntp == 0 || report.ntpSeconds != 0 || nearEraBoundary else { return }
            let valid: Bool
            switch leg {
            case .audio:
                valid = state.audio.report(ntp: ntp, rtp: report.rtpTimestamp, received: received)
            case .video:
                valid = state.video.report(ntp: ntp, rtp: report.rtpTimestamp, received: received)
            }
            if state.epoch == nil, ntp != 0 {
                state.epoch = Anchor(ntp: ntp, rtp: 0, received: received)
            }
            if !valid { state.videoOffset = nil; state.audioError = nil }
        }
    }

    func videoGenerationChanged(offer: UInt64, generation: UInt64) {
        state.withLock { state in
            guard state.active, state.offer == offer, generation > state.videoGeneration else { return }
            state.videoGeneration = generation
            state.video.lastSample = nil
            state.videoOffset = nil
            state.audioError = nil
        }
    }

    func videoPresented(offer: UInt64, generation: UInt64, timestamp: UInt32, nanos: UInt64) {
        state.withLock { state in
            guard state.active, state.offer == offer, state.videoGeneration == generation,
                  nanos > 0, let epoch = state.epoch,
                  nanos > (state.videoOffset?.presented ?? 0) else { return }
            guard let host = state.video.hostSeconds(rtp: timestamp, observed: nanos, epoch: epoch.ntp) else {
                if state.video.measuredRate == nil { state.videoOffset = nil }
                return
            }
            let offset = Self.localSeconds(nanos, since: epoch.received) - host
            if let prior = state.videoOffset, nanos - prior.presented <= Self.videoMaxAge {
                // Limit single-frame compositor/arrival outliers. Sustained
                // changes converge without holding any frame or audio block.
                let step = min(0.020, max(-0.020, offset - prior.seconds))
                state.videoOffset = (prior.seconds + step / 8, nanos)
            } else {
                state.videoOffset = (offset, nanos)
                state.audioError = nil
            }
        }
    }

    func resetAudioProjection(offer: UInt64?) {
        state.withLock { state in
            guard state.offer == offer else { return }
            state.audio.lastSample = nil
            state.audioError = nil
        }
    }

    func audioRouteChanged(offer: UInt64?, after renderBoundary: UInt64) {
        state.withLock { state in
            guard state.offer == offer else { return }
            state.audioRouteBoundary = max(state.audioRouteBoundary, renderBoundary)
            state.audioError = nil
            state.audioLatency = nil
        }
    }

    func audioErrorFrames(offer: UInt64, ssrc: UInt32, timestamp: UInt32, now: UInt64,
                          renderHostNanos: UInt64, playerSample: Int64, startSample: Int64,
                          outputLatency: Double) -> Double? {
        return state.withLock { state in
            guard state.active, state.offer == offer, state.audio.ssrc == ssrc else { return nil }
            let lead = (Double(startSample) - Double(playerSample)) / HPSSAudio.sampleRate + outputLatency
            // Both coordinates use Mach host time. Allow one microsecond for
            // conversion and rounding at the decision boundary.
            guard renderHostNanos > state.audioRouteBoundary, startSample >= playerSample,
                  outputLatency.isFinite, outputLatency >= 0,
                  Self.localSeconds(renderHostNanos, since: now) + lead >= -0.000_001,
                  let epoch = state.epoch, let displayed = state.videoOffset,
                  now >= displayed.presented, now - displayed.presented <= Self.videoMaxAge,
                  let audio = state.audio.anchor, let video = state.video.anchor,
                  Self.fresh(video, at: now),
                  abs(Self.ntpSeconds(audio.ntp, since: video.ntp) - Self.localSeconds(audio.received, since: video.received)) <= Self.maxReportSkew,
                  let host = state.audio.hostSeconds(rtp: timestamp, observed: now, epoch: epoch.ntp) else {
                state.audioError = nil
                return nil
            }
            // lastRenderTime.hostTime and the Metal timestamp are both Mach
            // host time. The paired sample coordinate comes from
            // playerTime(forNodeTime:) in the 48 kHz player timeline.
            if state.audioLatency.map({ abs(outputLatency - $0) >= Self.routeLatencyStep }) ?? true {
                state.audioLatency = outputLatency
                state.audioError = nil
            }
            let local = Self.localSeconds(renderHostNanos, since: epoch.received) + lead
            let error = local - host - displayed.seconds // positive = audio reaches output later
            guard abs(error) < 1 else { state.audioError = nil; return nil }
            let filtered = state.audioError.map { $0 + (error - $0) / 16 } ?? error
            state.audioError = filtered
            return filtered * HPSSAudio.sampleRate
        }
    }

    private static func fresh(_ anchor: Anchor, at now: UInt64) -> Bool {
        // A present can race with a report received just after it appeared.
        if now < anchor.received { return anchor.received - now <= 50_000_000 }
        return now - anchor.received <= reportMaxAge
    }

    private static func ntpSeconds(_ value: UInt64, since reference: UInt64) -> Double {
        Double(Int64(bitPattern: value &- reference)) / 4_294_967_296.0
    }

    private static func localSeconds(_ value: UInt64, since reference: UInt64) -> Double {
        value >= reference ? Double(value - reference) / 1e9 : -Double(reference - value) / 1e9
    }
}
