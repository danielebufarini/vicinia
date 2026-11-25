// Vicinia — live HPSS media transport and MediaFeedback.
// SPDX-License-Identifier: MIT
//
// Local UDP 5900 (audio + both legs' RTCP muxed) and 5901
// (video + video RTCP), RFC 5761 demux by second byte 192–223, SSRC group of
// consecutive SSRCs per tile, PT-101 keepalive every 0.5 s on the audio leg,
// RR every 0.5 s (+ empty SR every 5 s) on the video leg, audio RR every 1 s,
// RCTL every 50 ms alone in its datagram, rate-limited FIR/PLI/legacy-FIR.
// libsrtp with per-SSRC replay windows (SRTP and SRTCP),
// audio authenticated and discarded, packets buffered until the stripe group
// and canvas are known, feeding the shared MediaPipeline.

import Foundation
import Network

/// Liveness asks two distinct questions.
/// Transport: is the host still sending on the media legs? It sends RTCP and
/// audio-leg datagrams about once a second even for a static desktop, so
/// silence on both legs means the media path is interrupted, not idle.
/// Video progress: authenticated traffic says nothing about the picture.
/// When coded pictures keep arriving and none is presented, the decoder or
/// the presentation is stalled — never a static desktop, which owes nothing.
enum MediaLiveness: Sendable, Equatable {
    case stalled(seconds: Double)       // shown to the user while the session keeps waiting
    case resumed
    case lost(seconds: Double)          // bounded: no authenticated datagram at all
    case unshown(seconds: Double)       // bounded: pictures arrived for this long, none was presented
}

/// Invariant (why @unchecked Sendable is sound): every stored `var` is read and
/// written only on `queue`, the same serial queue as `MediaPipeline`; UDP
/// callbacks and timers are delivered on that queue.
final class MediaTransport: @unchecked Sendable {
    struct Counters: Sendable {
        var videoDatagrams = 0, audioDatagrams = 0, rtcpIn = 0
        var srtpAuthFailures = 0, srtpReplays = 0, srtpOtherErrors = 0, srtcpFailures = 0
        var audioDiscarded = 0, nonHEVCVideo = 0, bufferedBeforeResolution = 0, bufferOverflow = 0
        var rctlSent = 0, rrSent = 0, heartbeatsSent = 0, firSent = 0, sendErrors = 0
        var mediaStalls = 0                   // silences long enough to be shown
        var longestSilenceNanos: UInt64 = 0   // longest gap between authenticated datagrams
        var longestUnshownNanos: UInt64 = 0   // longest span of arriving pictures without a presentation
        var droppedByFaultInjection = 0
        var firstVideoNanos: UInt64?
        var lastVideoNanos: UInt64 = 0
        var videoBytes = 0                    // protected video-leg bytes received (effective bitrate)
        var hostSenderReports = 0
    }

    let queue: DispatchQueue
    private let pipeline: MediaPipeline
    private let evidence: EvidenceLog
    private let tiles: Int
    private var videoConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var videoIn: SRTPSession?, audioIn: SRTPSession?, videoOut: SRTPSession?, audioOut: SRTPSession?
    private var ourVideoSSRC: UInt32 = 0, ourAudioSSRC: UInt32 = 0
    private var stripeOf: [UInt32: Int]?
    private var canvasReady = false
    private var pending: [(Data, UInt64)] = []
    private var seenSSRCs: [UInt32: Int] = [:]
    private var extendedSeq: [UInt32: (seq: UInt16, roc: UInt32)] = [:]
    private var hostSR: [UInt32: (UInt32, UInt64)] = [:]
    private var audioRemote: (ssrc: UInt32, seq: UInt16)?
    private var rctl = RctlState()
    private var lastFIR: [Int: UInt64] = [:]
    private var firSequence: UInt8 = 0
    private var heartbeatSeq: UInt16 = 0, heartbeatTS: UInt32 = 0
    private var ticks = 0
    private var offerID: UInt64 = 0
    private var timers: [DispatchSourceTimer] = []
    private var stopped = false
    /// Media queue. Reports stalls, resumption and the bounded loss of media.
    var onLiveness: ((MediaLiveness) -> Void)?
    private var lastMediaNanos: UInt64 = 0
    private var lastLivenessCheck: UInt64 = 0
    private var stalled = false, lossReported = false
    /// Video progress is judged from here on (feedback start, a suspended process, an inactive display).
    private var progressFloor: UInt64 = 0
    static let stallIndicatorNanos: UInt64 = 1_500_000_000
    static let stallLimitNanos: UInt64 = 10_000_000_000
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Scripted physical recovery checks only (`-drop-media "start,seconds[,start,seconds…]"`,
    /// seconds after feedback starts): incoming datagrams are discarded as if the network lost them.
    private var dropWindows: [(start: UInt64, end: UInt64)] = []
    #endif
    private(set) var counters = Counters()
    static let localAudioPort: UInt16 = 5900, localVideoPort: UInt16 = 5901
    static let maxPendingPackets = 8192
    static let firMinIntervalNanos: UInt64 = 500_000_000

    init(pipeline: MediaPipeline, evidence: EvidenceLog, tiles: Int) {
        self.pipeline = pipeline
        self.queue = pipeline.queue
        self.evidence = evidence
        self.tiles = tiles
    }

    // MARK: setup (call on queue)

    /// `audioPort`/`videoPort` come from the host (media-init message 1).
    func bind(host: String, audioPort: UInt16, videoPort: UInt16) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let video = try Self.endpointPort(videoPort, "video"), audio = try Self.endpointPort(audioPort, "audio")
        let localVideo = try Self.endpointPort(Self.localVideoPort, "local video")
        let localAudio = try Self.endpointPort(Self.localAudioPort, "local audio")
        videoConnection = connect(host: host, remotePort: video, localPort: localVideo) { [weak self] in
            self?.ingestVideo($0)
        }
        audioConnection = connect(host: host, remotePort: audio, localPort: localAudio) { [weak self] in
            self?.handleAudioDatagram($0)
        }
        pipeline.onRecoveryNeeded = { [weak self] stripe in self?.requestRecovery(stripe: stripe) }
    }

    /// A negotiated UDP port; invalid server values are a controlled failure.
    static func endpointPort(_ value: UInt16, _ what: String) throws -> NWEndpoint.Port {
        guard value != 0, let port = NWEndpoint.Port(rawValue: value) else {
            throw SessionFailure.adaptiveUnavailable("invalid \(what) UDP port \(value)")
        }
        return port
    }

    /// Fresh keys for this offer generation. Each offer is a new media
    /// generation: nothing learnt from an earlier offer's stream (SSRC group,
    /// buffered packets, sequence/report/rate/FIR state, SRTP contexts, the
    /// pipeline's assembly/decoder state) carries over.
    func configure(keys: MediaKeys, videoSSRC: UInt32, audioSSRC: UInt32, offerID: UInt64 = 0) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        suspend()
        self.offerID = offerID
        stripeOf = nil
        canvasReady = false
        pending = []
        seenSSRCs = [:]
        extendedSeq = [:]
        hostSR = [:]
        audioRemote = nil
        rctl = RctlState()
        lastFIR = [:]
        firSequence = 0
        heartbeatSeq = 0; heartbeatTS = 0
        ticks = 0
        pipeline.updateStripeMap([:])
        pipeline.resetStream()
        videoIn = try SRTPSession(keySalt: keys.videoFromHost, inbound: true)
        audioIn = try SRTPSession(keySalt: keys.audioFromHost, inbound: true)
        videoOut = try SRTPSession(keySalt: keys.videoToHost, inbound: false)
        audioOut = try SRTPSession(keySalt: keys.audioToHost, inbound: false)
        ourVideoSSRC = videoSSRC
        ourAudioSSRC = audioSSRC
    }

    func canvasKnown(width: Int, height: Int, geometry: DesktopGeometry? = nil, offerID: UInt64 = 0) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.offerID = offerID
        pipeline.configureStream(canvas: (width, height), stripeCount: tiles, ssrcToStripe: stripeOf ?? [:],
                                 geometry: geometry, offerID: offerID)
        canvasReady = true
        pipeline.startPolling()                 // gap/marker/order timeouts without further packets
        flushIfResolved()
    }

    func startFeedback(defaults: UserDefaults = .standard) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timers.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastMediaNanos = now; lastLivenessCheck = 0; stalled = false; lossReported = false; progressFloor = now
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let plan = (defaults.string(forKey: "drop-media") ?? "").split(separator: ",").compactMap { Double($0) }
        dropWindows = stride(from: 0, to: plan.count - 1, by: 2).map {
            (now + UInt64(plan[$0] * 1e9), now + UInt64((plan[$0] + plan[$0 + 1]) * 1e9))
        }
        if !dropWindows.isEmpty {
            evidence.set("fault.dropMedia", dropWindows.map { "\($0.start)-\($0.end)" }.joined(separator: ","))
        }
        #endif
        addTimer(every: .milliseconds(50)) { $0.sendRCTL() }
        addTimer(every: .milliseconds(500)) { $0.tick() }
        tick()
    }

    /// Stops accepting the old media as soon as a resize/layout event begins.
    /// Keep the UDP sockets (and authenticated TCP session); the next offer
    /// supplies fresh SRTP contexts. The renderer retains its last valid image.
    func suspend() {
        dispatchPrecondition(condition: .onQueue(queue))
        for t in timers { t.cancel() }
        timers = []
        pipeline.stopPolling()
        pipeline.resetStream()
        videoIn = nil; audioIn = nil; videoOut = nil; audioOut = nil
        pending = []; stripeOf = nil; seenSSRCs = [:]; canvasReady = false
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        for t in timers { t.cancel() }
        timers = []
        pipeline.stopPolling()
        videoConnection?.cancel(); audioConnection?.cancel()
        videoConnection = nil; audioConnection = nil
        videoIn = nil; audioIn = nil; videoOut = nil; audioOut = nil
        pipeline.onRecoveryNeeded = nil
        pipeline.onFailure = nil
        onLiveness = nil
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        publishEvidence()
        #endif
    }

    private func connect(host: String, remotePort: NWEndpoint.Port, localPort: NWEndpoint.Port,
                         onDatagram: @escaping @Sendable (Data) -> Void) -> NWConnection {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: localPort)
        params.allowLocalEndpointReuse = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: remotePort, using: params)
        let evidence = self.evidence
        c.stateUpdateHandler = { state in
            evidence.set("udp.\(localPort.rawValue).state", "\(state)")
        }
        c.start(queue: queue)
        receive(on: c, onDatagram)
        return c
    }

    private func receive(on c: NWConnection, _ onDatagram: @escaping @Sendable (Data) -> Void) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty { onDatagram(data) }
            if error == nil { self.receive(on: c, onDatagram) } else {
                self.evidence.set("udp.receiveError", "\(error!)")
            }
        }
    }

    private func addTimer(every interval: DispatchTimeInterval, _ body: @escaping (MediaTransport) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in if let self, !self.stopped { body(self) } }
        t.resume()
        timers.append(t)
    }

    // MARK: receive

    private static func isRTCP(_ p: Data) -> Bool {
        p.count >= 2 && p[p.startIndex] & 0xC0 == 0x80 && (192...223).contains(p[p.startIndex + 1])
    }

    /// An authenticated datagram arrived from the host (either leg).
    private func noteMedia(_ now: UInt64) {
        if lastMediaNanos > 0, now &- lastMediaNanos > counters.longestSilenceNanos {
            counters.longestSilenceNanos = now &- lastMediaNanos
        }
        lastMediaNanos = now
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private func dropped(_ now: UInt64) -> Bool {
        guard !dropWindows.isEmpty, dropWindows.contains(where: { now >= $0.start && now < $0.end }) else { return false }
        counters.droppedByFaultInjection += 1
        return true
    }
    #endif

    /// Called every 0.5 s while feedback runs (`now` injected by tests).
    func checkLiveness(now: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        defer { lastLivenessCheck = now }
        // A check that arrives late means this process was suspended (background,
        // device lock): the silence was ours. Restart the clock and let recovery run.
        if lastLivenessCheck == 0 || now &- lastLivenessCheck > 2_000_000_000 { lastMediaNanos = now; progressFloor = now; return }
        let silent = now &- lastMediaNanos
        let unshown = Self.unshownNanos(pictures: (pipeline.lastPictureNanos, pipeline.pictureRunNanos),
                                        progress: pipeline.presentationProgress, floor: &progressFloor, now: now)
        counters.longestUnshownNanos = max(counters.longestUnshownNanos, unshown)
        if silent >= Self.stallLimitNanos {
            if !lossReported { lossReported = true; onLiveness?(.lost(seconds: Double(silent) / 1e9)) }
        } else if unshown >= Self.stallLimitNanos {
            if !lossReported { lossReported = true; onLiveness?(.unshown(seconds: Double(unshown) / 1e9)) }
        } else if max(silent, unshown) >= Self.stallIndicatorNanos {
            if !stalled { stalled = true; counters.mediaStalls += 1 }
            onLiveness?(.stalled(seconds: Double(max(silent, unshown)) / 1e9))
        } else if stalled {
            stalled = false
            onLiveness?(.resumed)
        }
    }

    /// For how long coded pictures have kept arriving without an actual
    /// presentation: up to the newest picture, from the latest of the last
    /// presentation, the floor and the start of the current run of pictures.
    /// The run start is what separates the onset of outstanding video work
    /// from the idle time before it: a desktop that was static for any length
    /// of time owes nothing when its next picture arrives. Zero for a static
    /// desktop, while the display side is not active (the floor moves along)
    /// and when the newest picture is older than the last presentation. One
    /// stray picture that is legitimately never shown (late, superseded)
    /// cannot grow this value: only pictures that keep arriving do.
    static func unshownNanos(pictures: (last: UInt64, runStart: UInt64), progress: (last: UInt64, displayActive: Bool),
                             floor: inout UInt64, now: UInt64) -> UInt64 {
        if !progress.displayActive { floor = now }
        let reference = max(progress.last, floor, pictures.runStart)
        return pictures.last > reference ? pictures.last - reference : 0
    }

    func ingestVideo(_ datagram: Data, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        dispatchPrecondition(condition: .onQueue(queue))
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if dropped(now) { return }
        #endif
        counters.videoDatagrams += 1
        counters.videoBytes += datagram.count
        if Self.isRTCP(datagram) { handleRTCP(datagram, session: videoIn, now: now); return }
        guard let videoIn else { return }
        let plain: Data
        do { plain = try videoIn.unprotectRTP(datagram) } catch SRTPError.authentication {
            counters.srtpAuthFailures += 1; return
        } catch SRTPError.replay { counters.srtpReplays += 1; return } catch { counters.srtpOtherErrors += 1; return }
        noteMedia(now)
        guard let rtp = try? RTPPacket(plain) else { counters.srtpOtherErrors += 1; return }
        guard rtp.payloadType == 100 else { counters.nonHEVCVideo += 1; return }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if counters.firstVideoNanos == nil { counters.firstVideoNanos = now; publishEvidence() }
        counters.lastVideoNanos = now
        #endif
        noteSequence(ssrc: rtp.ssrc, seq: rtp.sequence)
        if let map = stripeOf, canvasReady {
            if let stripe = map[rtp.ssrc] {
                rctl.onPacket(ssrc: rtp.ssrc, stripe: stripe, timestamp: rtp.timestamp, arrival: Double(now) / 1e9)
            }
            pipeline.ingest(plain, arrival: now)
            return
        }
        // Until the stripe group and canvas are known, keep packets in order (bounded).
        seenSSRCs[rtp.ssrc, default: 0] += 1
        if pending.count < Self.maxPendingPackets { pending.append((plain, now)); counters.bufferedBeforeResolution += 1 } else {
            counters.bufferOverflow += 1
        }
        if stripeOf == nil { resolveStripes() }
        flushIfResolved()
    }

    /// Stripe i is the i-th SSRC in a run of `tiles` consecutive SSRCs; when
    /// several runs exist, select the one with the most packets.
    private func resolveStripes() {
        let sorted = seenSSRCs.keys.sorted()
        var best: (base: UInt32, packets: Int)?
        for base in sorted {
            let run = (0..<tiles).map { base &+ UInt32($0) }
            guard run.allSatisfy({ seenSSRCs[$0] != nil }) else { continue }
            let n = run.reduce(0) { $0 + seenSSRCs[$1]! }
            if best == nil || n > best!.packets { best = (base, n) }
        }
        guard let best else { return }
        let map = Dictionary(uniqueKeysWithValues: (0..<tiles).map { (best.base &+ UInt32($0), $0) })
        stripeOf = map
        evidence.set("media.ssrcGroup.offer\(offerID)", map.sorted { $0.value < $1.value }.map { String(format: "0x%08x", $0.key) }.joined(separator: ","))
        evidence.set("media.ssrcGroup", map.sorted { $0.value < $1.value }.map { String(format: "0x%08x", $0.key) }.joined(separator: ","))
        if canvasReady { pipeline.updateStripeMap(map) }
    }

    private func flushIfResolved() {
        guard let map = stripeOf, canvasReady, !pending.isEmpty else { return }
        pipeline.updateStripeMap(map)
        let buffered = pending
        pending = []
        for (p, t) in buffered { pipeline.ingest(p, arrival: t) }
    }

    private func noteSequence(ssrc: UInt32, seq: UInt16) {
        if let e = extendedSeq[ssrc] {
            if seq < e.seq && e.seq &- seq > 0x8000 { extendedSeq[ssrc] = (seq, e.roc &+ 1) } else if seq &- e.seq < 0x8000 {
                extendedSeq[ssrc] = (seq, e.roc)
            }
        } else {
            extendedSeq[ssrc] = (seq, 0)
        }
    }

    private func handleAudioDatagram(_ datagram: Data) {
        let now = DispatchTime.now().uptimeNanoseconds
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if dropped(now) { return }
        #endif
        counters.audioDatagrams += 1
        if Self.isRTCP(datagram) { handleRTCP(datagram, session: audioIn, now: now); return }
        guard let audioIn else { return }
        // Audio playback is disabled: authenticate (including replay check) and discard.
        do {
            let plain = try audioIn.unprotectRTP(datagram)
            noteMedia(now)
            if let rtp = try? RTPPacket(plain) { audioRemote = (rtp.ssrc, rtp.sequence) }
            counters.audioDiscarded += 1
        } catch SRTPError.authentication { counters.srtpAuthFailures += 1 } catch SRTPError.replay {
            counters.srtpReplays += 1
        } catch { counters.srtpOtherErrors += 1 }
    }

    private func handleRTCP(_ datagram: Data, session: SRTPSession?, now: UInt64) {
        guard let session else { return }
        guard let plain = try? session.unprotectRTCP(datagram) else { counters.srtcpFailures += 1; return }
        noteMedia(now)
        counters.rtcpIn += 1
        for (ssrc, mid) in RTCPBuild.senderReports(plain) {
            hostSR[ssrc] = (mid, now)
            counters.hostSenderReports += 1
        }
    }

    // MARK: feedback

    private func send(_ data: Data, on c: NWConnection?) {
        c?.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.counters.sendErrors += 1 }
        })
    }

    private func sendRCTL() {
        guard let videoOut, let ts = rctl.lastTimestamp else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let pkt = RTCPBuild.rctl(sender: ourVideoSSRC, echoTimestamp: ts, holdMs: (now - rctl.lastArrival) * 1000,
                                 clockSeconds: now, delaySeconds: rctl.delaySeconds, received: rctl.received,
                                 bandwidthKbps: 60_000)
        guard let protected = try? videoOut.protectRTCP(pkt) else { return }
        send(protected, on: videoConnection)
        counters.rctlSent += 1
    }

    private func tick() {
        ticks += 1
        let now = DispatchTime.now().uptimeNanoseconds
        checkLiveness(now: now)
        // PT-101 keepalive payload (0x00683400) on the audio leg.
        if let audioOut {
            var w = ByteWriter(capacity: 16)
            w.u8(0x80); w.u8(101); w.u16(heartbeatSeq); w.u32(heartbeatTS); w.u32(ourAudioSSRC)
            w.append([0x00, 0x68, 0x34, 0x00])
            heartbeatSeq &+= 1; heartbeatTS &+= 480
            if let p = try? audioOut.protectRTP(w.bytes) { send(p, on: audioConnection); counters.heartbeatsSent += 1 }
        }
        // Video-leg RR (+ empty SR every 5 s) with one block per stripe SSRC.
        if let videoOut {
            let sources = (stripeOf ?? [:]).keys.sorted().map { ssrc -> (UInt32, UInt32, UInt32, UInt32) in
                let e = extendedSeq[ssrc] ?? (0, 0)
                let (lsr, dlsr) = Self.lsrDLSR(hostSR[ssrc], now: now)
                return (ssrc, (e.roc & 0xFFFF) << 16 | UInt32(e.seq), lsr, dlsr)
            }
            var pkt = RTCPBuild.rr(sender: ourVideoSSRC, sources: sources.map { ($0.0, $0.1, $0.2, $0.3) })
            if ticks % 10 == 0 { pkt = RTCPBuild.emptySR(sender: ourVideoSSRC) + pkt }
            if let p = try? videoOut.protectRTCP(pkt) { send(p, on: videoConnection); counters.rrSent += 1 }
        }
        // Audio-leg RR about once a second.
        if ticks % 2 == 0, let audioOut {
            var sources: [(UInt32, UInt32, UInt32, UInt32)] = []
            if let a = audioRemote {
                let (lsr, dlsr) = Self.lsrDLSR(hostSR[a.ssrc], now: now)
                sources.append((a.ssrc, UInt32(a.seq), lsr, dlsr))
            }
            if let p = try? audioOut.protectRTCP(RTCPBuild.rr(sender: ourAudioSSRC, sources: sources.map { ($0.0, $0.1, $0.2, $0.3) })) {
                send(p, on: audioConnection)
            }
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if ticks % 2 == 0 { publishEvidence() }
        #endif
    }

    private static func lsrDLSR(_ sr: (UInt32, UInt64)?, now: UInt64) -> (UInt32, UInt32) {
        guard let (mid, arrival) = sr else { return (0, 0) }
        return (mid, UInt32(truncatingIfNeeded: (now &- arrival) * 65536 / 1_000_000_000))
    }

    /// Irreversible compressed loss or decode failure on `stripe`: ask for a
    /// new random-access point (rate-limited per stripe; never NACK-based).
    func requestRecovery(stripe: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let videoOut, let map = stripeOf, let target = map.first(where: { $0.value == stripe })?.key else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let last = lastFIR[stripe], now &- last < Self.firMinIntervalNanos { return }
        lastFIR[stripe] = now
        firSequence &+= 1
        let pkt = RTCPBuild.recoveryRequest(sender: ourVideoSSRC, target: target, firSequence: firSequence)
        if let p = try? videoOut.protectRTCP(pkt) { send(p, on: videoConnection); counters.firSent += 1 }
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Value snapshot here; formatting on the evidence queue.
    func publishEvidence() {
        let c = counters, delay = rctl.delaySeconds
        evidence.deferred { log in
        var mbps = "n/a"
        if let first = c.firstVideoNanos, c.lastVideoNanos > first {
            mbps = String(format: "%.2f", Double(c.videoBytes) * 8 / (Double(c.lastVideoNanos - first) / 1e9) / 1e6)
        }
        log.set([
            "transport.videoBytes": "\(c.videoBytes)", "transport.videoMbps": mbps,
            "transport.mediaStalls": "\(c.mediaStalls)",
            "transport.longestSilenceMs": String(format: "%.0f", Double(c.longestSilenceNanos) / 1e6),
            "transport.longestUnshownMs": String(format: "%.0f", Double(c.longestUnshownNanos) / 1e6),
            "fault.droppedDatagrams": "\(c.droppedByFaultInjection)",
            "transport.videoDatagrams": "\(c.videoDatagrams)", "transport.audioDatagrams": "\(c.audioDatagrams)",
            "transport.rtcpIn": "\(c.rtcpIn)", "transport.hostSenderReports": "\(c.hostSenderReports)",
            "transport.srtpAuthFailures": "\(c.srtpAuthFailures)", "transport.srtpReplays": "\(c.srtpReplays)",
            "transport.srtpOtherErrors": "\(c.srtpOtherErrors)", "transport.srtcpFailures": "\(c.srtcpFailures)",
            "transport.audioDiscarded": "\(c.audioDiscarded)", "transport.nonHEVCVideo": "\(c.nonHEVCVideo)",
            "transport.bufferedBeforeResolution": "\(c.bufferedBeforeResolution)",
            "transport.bufferOverflow": "\(c.bufferOverflow)",
            "feedback.rctlSent": "\(c.rctlSent)", "feedback.rrSent": "\(c.rrSent)",
            "feedback.heartbeatsSent": "\(c.heartbeatsSent)", "feedback.firSent": "\(c.firSent)",
            "feedback.sendErrors": "\(c.sendErrors)",
            "feedback.rctlDelayMs": String(format: "%.2f", delay * 1000),
        ])
        }
    }
    #endif
}
