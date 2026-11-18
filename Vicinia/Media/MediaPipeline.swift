// Vicinia — media pipeline: plaintext RTP → AUs → VideoToolbox → desktop updates.
// SPDX-License-Identifier: MIT
//
// Parameter-set harvesting (VPS/SPS/PPS keyed by pps id, accumulated across
// groups) and IRAP gating use one decoder generation per parameter-set
// change, random access before decode, global DONL decode order across
// stripes and update membership in decode order.

import CoreMedia
import Foundation
import Synchronization
import VideoToolbox

/// While a random-access point is awaited after a loss: repeat the recovery
/// request at a bounded rate, and give up after a bounded time.
/// Pure state with injected time; owned by the media queue.
struct RecoveryRetry {
    enum Action: Equatable { case none, request, giveUp }
    static let intervalNanos: UInt64 = 600_000_000
    static let limitNanos: UInt64 = 6_000_000_000
    private(set) var since: UInt64?
    private var lastRequest: UInt64 = 0
    private var gaveUp = false

    /// A loss just requested recovery. Further losses do not extend the bound.
    mutating func begin(now: UInt64) {
        if since == nil { since = now; gaveUp = false }
        lastRequest = now
    }
    /// A random-access point was accepted: returns how long recovery took.
    mutating func end(now: UInt64) -> UInt64? {
        defer { since = nil }
        return since.map { now &- $0 }
    }
    mutating func poll(now: UInt64) -> Action {
        guard let since, !gaveUp else { return .none }
        if now &- since >= Self.limitNanos { gaveUp = true; return .giveUp }
        guard now &- lastRequest >= Self.intervalNanos else { return .none }
        lastRequest = now
        return .request
    }
}

/// What to do about a decoder failure. A random-access picture re-roots a
/// healthy session; it cannot repair a session the system invalidated (for
/// example while the app was in the background) or one that fails on the
/// random-access picture itself: then the decoder is rebuilt from the retained
/// parameter sets — a bounded number of times, never in a loop.
struct DecoderRebuildPolicy {
    enum Action: Equatable { case awaitRandomAccess, rebuild, giveUp }
    static let maxRebuilds = 3
    static let windowNanos: UInt64 = 10_000_000_000
    private var rebuilds: [UInt64] = []

    mutating func onFailure(status: OSStatus, wasRandomAccess: Bool, now: UInt64) -> Action {
        guard status == kVTInvalidSessionErr || wasRandomAccess else { return .awaitRandomAccess }
        rebuilds.removeAll { now &- $0 > Self.windowNanos }
        guard rebuilds.count < Self.maxRebuilds else { return .giveUp }
        rebuilds.append(now)
        return .rebuild
    }
}

/// Thread-safe counters (decoder output arrives on VideoToolbox threads).
final class MediaCounters: Sendable {
    struct Values: Sendable {
        var decodeSubmitted = 0, decoded = 0, decodeFailed = 0, lastFailure: OSStatus = 0
        var accessUnits = 0, lostAUs = 0, skippedBeforeRandomAccess = 0, waitingForParameterSets = 0
        var nonVCLSkipped = 0, generations = 0, sourceUpdates = 0, recoveryRequests = 0
        var decodeOrderHeldMax = 0, staleDecoderFailures = 0
        var recoveryRetries = 0, recoveries = 0, recoveryGiveUps = 0, decoderRebuilds = 0
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        /// Loss detected → random-access point accepted, most recent first-in order (bounded).
        var recoveryMs: [Double] = []
        var firstSourceNanos: UInt64 = 0, lastSourceNanos: UInt64 = 0
        /// Previous stripe of an update submitted → first packet of its next
        /// stripe: the gap the settle rule has to bridge. Buckets: already
        /// arriving, ≤0.5, ≤1, ≤2, ≤3, ≤5 ms, and >5 ms (a split commit).
        var stripeGaps = [Int](repeating: 0, count: 7)
        var stripeGapMaxNanos: UInt64 = 0
        #endif
        var lossReasons: [String: Int] = [:]
        var orderSkips: [String: Int] = [:]
    }
    private let v = Mutex(Values())
    func update(_ body: (inout Values) -> Void) { v.withLock { body(&$0) } }
    var snapshot: Values { v.withLock { $0 } }
}

/// Owned by one serial queue; replay and live network receive both
/// call `ingest` on that queue.
/// Invariant (why @unchecked Sendable is sound): every stored `var` is read and
/// written only on `queue`; the class is shared across threads only to enqueue
/// work there. Thread-crossing outputs go through Sendable `mailbox`/`counters`.
final class MediaPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "it.danielebufarini.vicinia.media", qos: .userInteractive)
    let counters = MediaCounters()
    private let mailbox: DesktopUpdateMailbox
    private let evidence: EvidenceLog
    private var stripeCount: Int
    private var canvas: (width: Int, height: Int)?
    private var geometry: DesktopGeometry?
    private var offerID: UInt64 = 0
    private var ssrcToStripe: [UInt32: Int]
    private let ruleOverride: StripeLayout.Rule?
    /// Live source (MediaTransport) asks the host for a new random-access point.
    var onRecoveryNeeded: ((Int) -> Void)?
    /// Recovery was given up (bounded): the session must end with this readable reason.
    var onFailure: ((String) -> Void)?
    private var recovery = RecoveryRetry()
    private var rebuildPolicy = DecoderRebuildPolicy()
    private var lastRandomAccessTimestamp: UInt32?
    private var assembler: HEVCAssembler
    private var order = DecodeOrderBuffer()
    private var decoder: HEVCDecoder?
    private var vps: Data?, sps: Data?
    private var pps: [UInt64: Data] = [:]
    /// Media/display generation: bumped by every stream reset and decoder rebuild.
    private var generation: UInt64 = 0
    private var awaitingRandomAccess = true
    private var lastSourceTimestamp: UInt32?
    /// When the newest coded picture (an access unit with VCL data) arrived:
    /// from then on a presentation is owed (media-stall check).
    private(set) var lastPictureNanos: UInt64 = 0
    /// When the current run of arriving pictures began. A picture that follows
    /// `MediaTransport.stallIndicatorNanos` without any picture starts a new
    /// run: the static desktop before it is not outstanding video work.
    private(set) var pictureRunNanos: UInt64 = 0
    var presentationProgress: (last: UInt64, displayActive: Bool) { mailbox.presentationProgress }
    func notePicture(now: UInt64) {
        if lastPictureNanos == 0 || now >= lastPictureNanos + MediaTransport.stallIndicatorNanos { pictureRunNanos = now }
        lastPictureNanos = now
    }
    /// The update (RTP timestamp) whose stripes are being submitted; it is final
    /// when its last stripe index or a newer timestamp is submitted (mailbox),
    /// or after `updateSettleNanos` without any of its stripes still arriving.
    private var openUpdate: (timestamp: UInt32, lastSubmit: UInt64)?
    /// The update closed last (whatever closed it), to measure a stripe that still arrives for it.
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private var lastSubmitted: (timestamp: UInt32, lastSubmit: UInt64)?
    #endif
    private var pollTimer: DispatchSourceTimer?
    /// One-shot, re-armed at every submission of a still-open update (live path).
    private var settleTimer: DispatchSourceTimer?
    /// Fork session.py `_FRAME_TILE_GAP_S` (5 ms).
    static let updateSettleNanos: UInt64 = 5_000_000

    init(ssrcToStripe: [UInt32: Int], canvas: (width: Int, height: Int)?,
         ruleOverride: StripeLayout.Rule?, mailbox: DesktopUpdateMailbox, evidence: EvidenceLog) {
        let map = ssrcToStripe
        self.stripeCount = (map.values.max() ?? 0) + 1
        self.canvas = canvas
        self.ssrcToStripe = map
        self.ruleOverride = ruleOverride
        self.mailbox = mailbox
        self.evidence = evidence
        assembler = HEVCAssembler(stripeForSSRC: { map[$0] })
    }

    /// Live session: geometry from the media answer/layout, stripes from the
    /// observed SSRC group. Resets the stream for the new configuration.
    func configureStream(canvas: (Int, Int), stripeCount: Int, ssrcToStripe: [UInt32: Int],
                         geometry: DesktopGeometry? = nil, offerID: UInt64 = 0) {
        dispatchPrecondition(condition: .onQueue(queue))
        resetStream()
        self.canvas = (canvas.0, canvas.1)
        self.geometry = geometry
        self.offerID = offerID
        self.stripeCount = stripeCount
        updateStripeMap(ssrcToStripe)
        evidence.set("media.canvas", "\(canvas.0)x\(canvas.1) stripes \(stripeCount)")
    }

    func updateStripeMap(_ map: [UInt32: Int]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard map != ssrcToStripe else { return }
        resetStream()                           // another SSRC group is another stream
        ssrcToStripe = map
        assembler = HEVCAssembler(stripeForSSRC: { map[$0] })
    }

    // MARK: queue-confined API

    /// Mailbox state is locked; also safe from the session owner when accepting
    /// an asynchronous presentation notification.
    func isCurrent(generation: UInt64) -> Bool { mailbox.isCurrent(generation: generation) }

    func ingest(_ packet: Data, arrival: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        for output in assembler.ingest(packet, arrivalNanos: arrival) { handle(output, now: arrival) }
    }

    /// Expires assembler gaps/markers and decode-order gaps and closes settled
    /// updates when no packet arrives (replay pump, live `startPolling`).
    func poll(now: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        for output in assembler.poll(now: now) { handle(output, now: now) }
        for event in order.poll(now: now) { handle(event, now: now) }
        if let open = openUpdate, now &- open.lastSubmit >= Self.updateSettleNanos,
           !assembler.isAssembling(timestamp: open.timestamp), !order.holds(timestamp: open.timestamp) {
            mailbox.noteFinal(rtpTimestamp: open.timestamp, generation: generation)
            openUpdate = nil
        }
        switch recovery.poll(now: now) {
        case .none: break
        case .request:                                  // the earlier request or its answer was lost
            counters.update { $0.recoveryRetries += 1 }
            onRecoveryNeeded?(0)                        // the random-access picture comes on the first stripe
        case .giveUp:
            counters.update { $0.recoveryGiveUps += 1 }
            onFailure?("no random-access picture from the Mac for \(RecoveryRetry.limitNanos / 1_000_000_000) s after a media loss")
        }
    }

    /// Live path: drives `poll` on this serial queue even when no packet arrives.
    func startPolling(every interval: DispatchTimeInterval = .milliseconds(5)) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll(now: DispatchTime.now().uptimeNanoseconds) }
        t.resume()
        pollTimer = t
    }

    func stopPolling() {
        dispatchPrecondition(condition: .onQueue(queue))
        pollTimer?.cancel()
        pollTimer = nil
        settleTimer?.cancel()
        settleTimer = nil
    }

    /// Measured: an update without the last stripe became final
    /// only at the next 5 ms poll after its settle time, i.e. 5–10 ms after its
    /// last submission. The rule is unchanged; this checks it exactly when the
    /// settle time has passed. If a stripe is still arriving then, the periodic
    /// poll closes the update later, as before.
    private func armSettleCheck(lastSubmit: UInt64) {
        guard pollTimer != nil else { return }              // live path only; replay is pumped
        if settleTimer == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.setEventHandler { [weak self] in self?.poll(now: DispatchTime.now().uptimeNanoseconds) }
            t.schedule(deadline: .distantFuture)
            t.resume()
            settleTimer = t
        }
        settleTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: lastSubmit &+ Self.updateSettleNanos),
                              leeway: .microseconds(100))
    }

    /// Ends the current stream: decoder drained and invalidated off MainActor;
    /// a new generation makes every older callback and committed update obsolete.
    func resetStream() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        mailbox.reset(generation: generation, layout: nil)
        decoder?.invalidate()
        decoder = nil
        vps = nil; sps = nil; pps = [:]
        assembler.reset()
        order.reset()
        openUpdate = nil
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        lastSubmitted = nil
        #endif
        awaitingRandomAccess = true
        lastSourceTimestamp = nil
        lastPictureNanos = 0; pictureRunNanos = 0
        recovery = RecoveryRetry()
        rebuildPolicy = DecoderRebuildPolicy()
        lastRandomAccessTimestamp = nil
    }

    /// Media queue: takes value snapshots only; the strings are built on the
    /// evidence queue (nothing diagnostic runs per packet or on this queue).
    func publishEvidence() {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        dispatchPrecondition(condition: .onQueue(queue))
        let c = counters.snapshot
        let a = assembler.counters
        evidence.deferred { log in
        var rate = "n/a"
        if c.sourceUpdates > 1, c.lastSourceNanos > c.firstSourceNanos {
            rate = String(format: "%.2f", Double(c.sourceUpdates - 1) / (Double(c.lastSourceNanos - c.firstSourceNanos) / 1e9))
        }
        log.set([
            "media.rtpPackets": "\(a.packets)", "media.rtpMalformed": "\(a.malformed)",
            "media.rtpDuplicates": "\(a.duplicates)", "media.rtpUnknownSSRC": "\(a.unknownSSRC)",
            "media.rtpForeignPT": "\(a.foreignPayloadType)", "media.lateAfterFlush": "\(a.late)",
            "media.accessUnits": "\(c.accessUnits)", "media.lostAUs": "\(c.lostAUs)",
            "media.lossReasons": "\(c.lossReasons)",
            "media.skippedBeforeRandomAccess": "\(c.skippedBeforeRandomAccess)",
            "media.decodeOrderSkips": "\(c.orderSkips)",
            "media.decodeOrderHeldMax": "\(c.decodeOrderHeldMax)",
            "media.waitingForParameterSets": "\(c.waitingForParameterSets)",
            "media.nonVCLSkipped": "\(c.nonVCLSkipped)",
            "media.recoveryRequests": "\(c.recoveryRequests)",
            "media.recoveryRetries": "\(c.recoveryRetries)", "media.recoveryGiveUps": "\(c.recoveryGiveUps)",
            "media.recoveries": "\(c.recoveries)",
            "media.recoveryMs": c.recoveryMs.map { String(format: "%.1f", $0) }.joined(separator: ","),
            "decoder.rebuilds": "\(c.decoderRebuilds)",
            "decoder.submitted": "\(c.decodeSubmitted)", "decoder.decoded": "\(c.decoded)",
            "decoder.failed": "\(c.decodeFailed)", "decoder.lastFailureStatus": "\(c.lastFailure)",
            "decoder.staleGenerationFailures": "\(c.staleDecoderFailures)",
            "decoder.generations": "\(c.generations)",
            "source.desktopUpdates": "\(c.sourceUpdates)", "source.desktopUpdatesPerSecond": rate,
            "updates.interStripeGapMs": zip(["arriving", "≤0.5", "≤1", "≤2", "≤3", "≤5", ">5"], c.stripeGaps)
                .map { "\($0)=\($1)" }.joined(separator: " ") + String(format: " max=%.2f", Double(c.stripeGapMaxNanos) / 1e6),
        ])
        }
        #endif
    }

    // MARK: -

    private func handle(_ output: AssemblerOutput, now: UInt64) {
        switch output {
        case .lost(let ssrc, let timestamp, let reason):
            counters.update { $0.lostAUs += 1; $0.lossReasons[reason, default: 0] += 1 }
            // Irreversible compressed loss: realign at the next random-access
            // point instead of feeding a broken reference chain; request one.
            mailbox.noteAbandoned(rtpTimestamp: timestamp, generation: generation)
            beginRecovery(stripe: ssrcToStripe[ssrc] ?? 0, now: now)
            for event in order.realign(now: now) { handle(event, now: now) }
        case .accessUnit(let au):
            counters.update { $0.accessUnits += 1 }
            let events = order.push(au, now: now)
            let held = order.heldCount
            counters.update { $0.decodeOrderHeldMax = max($0.decodeOrderHeldMax, held) }
            for event in events { handle(event, now: now) }
        }
    }

    private func handle(_ event: DecodeOrderBuffer.Event, now: UInt64) {
        switch event {
        case .decode(let au):
            submit(au, now: now)
        case .skip(let au, let reason):
            counters.update { $0.orderSkips[reason, default: 0] += 1 }
            if reason == "before random access" {
                mailbox.noteAbandoned(rtpTimestamp: au.rtpTimestamp, generation: generation)
                if openUpdate?.timestamp == au.rtpTimestamp { openUpdate = nil }
            }
        case .gap:
            // A whole picture is missing in decode order (the order buffer has
            // already realigned). The IDR comes on the first stripe.
            counters.update { $0.lostAUs += 1; $0.lossReasons["decode-order gap", default: 0] += 1 }
            beginRecovery(stripe: 0, now: now)
        }
    }

    /// Shared DPB is broken: no non-IRAP picture is fed until the next random
    /// access point; the update being submitted can no longer be coherent.
    private func beginRecovery(stripe: Int, now: UInt64) {
        awaitingRandomAccess = true
        abandonOpenUpdate()
        counters.update { $0.recoveryRequests += 1 }
        recovery.begin(now: now)
        onRecoveryNeeded?(stripe)
    }

    private func abandonOpenUpdate() {
        guard let open = openUpdate else { return }
        mailbox.noteAbandoned(rtpTimestamp: open.timestamp, generation: generation)
        openUpdate = nil
    }

    /// Decoder output failure (VideoToolbox thread → queue). Only the current
    /// generation's decoder matters; the shared session is kept and re-rooted by
    /// the next IRAP, never rebuilt per stripe.
    private func decoderFailed(stripe: Int, rtpTimestamp: UInt32, status: OSStatus, generation gen: UInt64, now: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard gen == generation, decoder != nil else {
            counters.update { $0.staleDecoderFailures += 1 }
            return
        }
        switch rebuildPolicy.onFailure(status: status, wasRandomAccess: rtpTimestamp == lastRandomAccessTimestamp, now: now) {
        case .awaitRandomAccess:
            beginRecovery(stripe: stripe, now: now)
        case .rebuild:
            // New generation from the retained parameter sets; later callbacks
            // of the dead session are stale. It still needs a random-access picture.
            counters.update { $0.decoderRebuilds += 1 }
            evidence.set("decoder.rebuild.gen\(generation)", "status \(status) at ts \(rtpTimestamp)")
            if let vps, let sps { rebuildDecoder(vps: vps, sps: sps) }
            beginRecovery(stripe: 0, now: now)
        case .giveUp:
            onFailure?("the hardware decoder kept failing (status \(status)) after \(DecoderRebuildPolicy.maxRebuilds) rebuilds")
            return
        }
        for event in order.realign(now: now) { handle(event, now: now) }
    }

    private func submit(_ au: AccessUnit, now: UInt64) {
        var vcl: [Data] = []
        var changed = false
        for nal in au.nalUnits {
            let type = HEVCNAL.type(nal[nal.startIndex])
            switch type {
            case HEVCNAL.vps: if vps != nal { vps = nal; changed = true }
            case HEVCNAL.sps: if sps != nal { sps = nal; changed = true }
            case HEVCNAL.pps:
                var r = BitReader(hevcRBSP(nal.dropFirst(2)))
                if let id = try? r.ue(), pps[id] != nal { pps[id] = nal; changed = true }
            default:
                if HEVCNAL.isVCL(type) { vcl.append(nal) } else { counters.update { $0.nonVCLSkipped += 1 } }
            }
        }
        if changed, let vps, let sps, !pps.isEmpty { rebuildDecoder(vps: vps, sps: sps) }
        if !vcl.isEmpty { notePicture(now: now) }
        guard let decoder, !vcl.isEmpty else {
            if !vcl.isEmpty { counters.update { $0.waitingForParameterSets += 1 } }
            return
        }
        if awaitingRandomAccess {
            guard au.containsIRAP else {
                counters.update { $0.skippedBeforeRandomAccess += 1 }
                if openUpdate?.timestamp == au.rtpTimestamp { abandonOpenUpdate() }
                return
            }
            awaitingRandomAccess = false
            let recoveryTime = recovery.end(now: now)
            if recoveryTime != nil {
                counters.update {
                    $0.recoveries += 1
                    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                    if let recoveryTime, $0.recoveryMs.count < 64 { $0.recoveryMs.append(Double(recoveryTime) / 1e6) }
                    #endif
                }
            }
            evidence.set("media.randomAccess.gen\(generation)", "stripe \(au.stripe) ts \(au.rtpTimestamp) donl \(au.donl.map(String.init) ?? "-")")
        }
        if au.containsIRAP { lastRandomAccessTimestamp = au.rtpTimestamp }
        if lastSourceTimestamp != au.rtpTimestamp {
            lastSourceTimestamp = au.rtpTimestamp
            counters.update {
                $0.sourceUpdates += 1
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                if $0.firstSourceNanos == 0 { $0.firstSourceNanos = au.completedNanos }
                $0.lastSourceNanos = au.completedNanos
                #endif
            }
        }
        counters.update {
            $0.decodeSubmitted += 1
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if let previous = lastSubmitted, previous.timestamp == au.rtpTimestamp {
                let gap = au.firstArrivalNanos > previous.lastSubmit ? au.firstArrivalNanos - previous.lastSubmit : 0
                let limits: [UInt64] = [0, 500_000, 1_000_000, 2_000_000, 3_000_000, 5_000_000]
                $0.stripeGaps[limits.firstIndex { gap <= $0 } ?? limits.count] += 1
                $0.stripeGapMaxNanos = max($0.stripeGapMaxNanos, gap)
            }
            #endif
        }
        // Update membership in decode order, recorded before the (possibly
        // synchronous) failure report of `decode`.
        mailbox.noteSubmitted(stripe: au.stripe, rtpTimestamp: au.rtpTimestamp, generation: generation)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        lastSubmitted = (au.rtpTimestamp, now)
        #endif
        openUpdate = au.stripe == stripeCount - 1 ? nil : (au.rtpTimestamp, now)
        if openUpdate != nil { armSettleCheck(lastSubmit: now) }
        decoder.decode(au, vclNALs: vcl, now: DispatchTime.now().uptimeNanoseconds)
    }

    private func rebuildDecoder(vps: Data, sps: Data) {
        generation += 1
        mailbox.reset(generation: generation, layout: nil)
        decoder?.invalidate()
        decoder = nil
        awaitingRandomAccess = true
        openUpdate = nil
        let sets = [vps, sps] + pps.keys.sorted().compactMap { pps[$0] }
        let parsed: HEVCSequenceParameters
        do { parsed = try HEVCSequenceParameters(spsNAL: sps) } catch {
            evidence.set("sps.parseError.gen\(generation)", "\(error)")
            return
        }
        let rule = ruleOverride ?? (parsed.hasConformanceWindow ? .conformanceWindow : .codedStack)
        let perStripe = rule == .conformanceWindow ? parsed.visibleHeight : parsed.codedHeight
        let layout = StripeLayout(
            rule: rule, stripeCount: stripeCount,
            canvasWidth: canvas?.width ?? parsed.visibleWidth,
            canvasHeight: canvas?.height ?? perStripe * stripeCount,
            pictureWidth: parsed.codedWidth, pictureHeight: parsed.codedHeight,
            cropTop: parsed.cropTop, visibleHeight: parsed.visibleHeight, geometry: geometry, offerID: offerID)
        guard parsed.visibleWidth == layout.canvasWidth,
              (0..<stripeCount).allSatisfy({ layout.placement(stripe: $0).rows > 0 }),
              perStripe * stripeCount >= layout.canvasHeight else {
            evidence.set("media.geometryMismatch", "offer \(offerID): \(layout.summary); SPS \(parsed.summary)")
            return
        }
        mailbox.reset(generation: generation, layout: layout)
        let counters = self.counters, mailbox = self.mailbox, queue = self.queue
        let sink: @Sendable (DecoderEvent) -> Void = { [weak self] event in
            switch event {
            case .decoded(let d):
                counters.update { $0.decoded += 1 }
                mailbox.deliver(d)
            case .failed(let stripe, let ts, let gen, let status):
                counters.update { $0.decodeFailed += 1; $0.lastFailure = status }
                mailbox.noteFailed(stripe: stripe, rtpTimestamp: ts, generation: gen)
                if let pipeline = self {
                    queue.async {
                        pipeline.decoderFailed(stripe: stripe, rtpTimestamp: ts, status: status, generation: gen,
                                               now: DispatchTime.now().uptimeNanoseconds)
                    }
                }
            }
        }
        var attempts: [String] = []
        for format in [kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, nil] as [OSType?] {
            do {
                let d = try HEVCDecoder(parameterSets: sets, generation: generation, pixelFormat: format, sink: sink)
                decoder = d
                attempts.append("\(d.facts.requestedPixelFormat): created")
                evidence.set([
                    "decoder.requireHardwareAcceleratedVideoDecoder": "true",
                    "decoder.usingHardwareAcceleratedVideoDecoder":
                        d.facts.usingHardware.map(String.init) ?? "property unavailable",
                    "decoder.requestedOutput": d.facts.requestedPixelFormat,
                ])
                break
            } catch {
                attempts.append("\(format.map(fourCC) ?? "native"): \(error)")
            }
        }
        counters.update { $0.generations += 1 }
        evidence.set([
            "decoder.creationAttempts.gen\(generation)": attempts.joined(separator: " | "),
            "sps.gen\(generation)": parsed.summary,
            "parameterSets.gen\(generation)": "VPS \(vps.count)B, SPS \(sps.count)B, PPS×\(pps.count)",
            "layout.gen\(generation)": layout.summary,
            "media.offerForGeneration.\(generation)": "\(offerID)",
        ])
        print("[vicinia] gen \(generation) SPS \(parsed.summary) decoder \(attempts) hw=\(decoder?.facts.usingHardware.map(String.init) ?? "n/a")")
    }
}
