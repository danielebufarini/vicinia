// Vicinia — native HPSS Adaptive session: one serialized owner for the
// state machine, authentication, encrypted control, display/media negotiation
// and teardown.
// SPDX-License-Identifier: MIT
//
// Ordering, verified on the macOS 27.2.1 host: plaintext ViewerInfo +
// 0x12, 0x1d, SetEncodings (without 1010) → plaintext FBU carrying the 1103
// rekey → 0x12 toggle → encrypted SetEncodings → media-init message 1 →
// one 0x1c + FBU request → answer (message 2) or error (message 3).
// Own viewer identity, exact-length plaintext reads, fail-closed records,
// one offer and at most one fresh-key retry.

import Foundation

enum SessionPhase: String, Sendable {
    case idle, connecting, rfbHandshake, authenticating, encryptedControl, virtualDisplayReady
    case awaitingMediaInit, mediaNegotiating, awaitingRandomAccess, streaming, disconnecting, failed
    case resizing, hostReconfiguring
}

enum SessionFailure: Error, CustomStringConvertible {
    case otherConsoleUser
    case noMediaInit
    case offerRefused(String)
    case noAnswer
    case adaptiveUnavailable(String)
    case protocolViolation(String)
    case mediaLost(String)

    var description: String {
        switch self {
        case .otherConsoleUser: "another user is logged in at the Mac (SessionSelect); not supported"
        case .noMediaInit: "Adaptive unavailable: no media-init message 1"
        case .offerRefused(let w): "Adaptive offer refused by the Mac: \(w)"
        case .noAnswer: "Adaptive unavailable: no answer to the media offer"
        case .adaptiveUnavailable(let w): "Adaptive unavailable: \(w)"
        case .protocolViolation(let w): "control protocol violation: \(w)"
        case .mediaLost(let w): "video from the Mac stopped (\(w)); close and reconnect"
        }
    }
}

struct SessionConfiguration: Sendable {
    var host: String
    var port: UInt16 = 5900
    var username: String
    var logicalWidth: Int
    var logicalHeight: Int
    var hidpiScale: Double = 2
    var clientName = "Vicinia 0.1"
    var hardwareModel: String
    var osBuild: String
    var osVersion: (Int, Int, Int)
}

actor HPSSSession {
    private let config: SessionConfiguration
    private var password: SecretBytes?
    private let channel: ControlChannel
    private let pipeline: MediaPipeline
    private let evidence: EvidenceLog
    private let onPhase: @Sendable (SessionPhase, String) -> Void
    private let trust: @Sendable (String, String) async -> Bool
    private var records: RecordLayer?
    private var transport: MediaTransport?
    /// LTRP flag of the latest video answer, paired with the offer it answers.
    private var answerLTRP: (offer: UInt64, value: LTRPNegotiation)?
    private var pending: [UInt8] = []
    private(set) var phase: SessionPhase = .idle
    private var layout: DisplayLayout?
    private var desired: DisplayRequest
    private var lastRequested: DisplayRequest
    private var mediaInitSerial = 0
    private var consumedMediaInit = 0
    private var boundPorts: (audio: UInt16, video: UInt16)?
    private var offerSerial: UInt64 = 0
    private var currentOffer: UInt64 = 0
    private var offeredGeometry: DesktopGeometry?
    private var resizeSerial = 0
    private var resizing: (id: Int, request: DisplayRequest, sent: UInt64)?
    private var transitionTimeout: Task<Void, Never>?
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private var resizeTimes: [Double] = []
    #endif
    private var mediaPorts: (audio: UInt16, video: UInt16)?
    private var stats: [String: Int] = [:]
    private var finished = false
    private var tearingDown = false
    private var input = InputState()
    private var cursors = CursorCache()
    var onInputEpoch: (@Sendable (UInt64, Bool) -> Void)?
    var onCursor: (@Sendable (CursorImage?, Bool) -> Void)?
    /// Seconds without media while streaming (nil: media is flowing again).
    var onMediaStall: (@Sendable (Double?) -> Void)?
    func bindMediaStall(_ handler: @escaping @Sendable (Double?) -> Void) { onMediaStall = handler }

    // MARK: media recovery: bounded, no automatic reconnect

    private func mediaLiveness(_ event: MediaLiveness) async {
        guard !finished, phase == .streaming else { return }
        switch event {
        case .stalled(let seconds):
            stats["mediaStallReports", default: 0] += 1
            onMediaStall?(seconds)
        case .resumed:
            onMediaStall?(nil)
        case .lost(let seconds):
            await failMedia(String(format: "no media for %.0f s", seconds))
        case .unshown(let seconds):
            await failMedia(String(format: "pictures kept arriving for %.0f s but none could be shown", seconds))
        }
    }

    /// Media cannot be recovered. The control channel is still trusted, so held
    /// input is released before the session ends with a readable failure.
    private func failMedia(_ reason: String) async {
        guard !finished, [.streaming, .awaitingRandomAccess].contains(phase) else { return }
        let failure = SessionFailure.mediaLost(reason)
        evidence.set("session.failure", "\(phase.rawValue): \(failure)")
        enter(.failed, "\(phase.rawValue): \(failure)")
        await teardown()
    }

    func bindInput(epoch: @escaping @Sendable (UInt64, Bool) -> Void,
                   cursor: @escaping @Sendable (CursorImage?, Bool) -> Void) {
        onInputEpoch = epoch; onCursor = cursor
    }

    func dispatchInput(_ event: RemoteInput, epoch: UInt64) async {
        guard input.accepts(epoch: epoch) else { return }
        do {
            try await sendWrite(.input(event, epoch: epoch))
            stats["inputDispatches", default: 0] += 1
        } catch { await fail(error) }
    }

    /// Non-terminal release of dispatched presses. Completion has the existing
    /// writer/network-stack acceptance meaning; it is not a remote receipt ack.
    /// Keep the epoch intact, and reject transitions on both sides of the await.
    func releaseInputForOverflow(epoch: UInt64) async -> Bool {
        guard input.accepts(epoch: epoch), phase == .streaming,
              !finished, !tearingDown, records != nil else { return false }
        do {
            try await sendWrite(.release) // an empty ledger still awaits the serialized barrier
            return input.accepts(epoch: epoch) && phase == .streaming
                && !finished && !tearingDown && records != nil
        } catch {
            await fail(error)
            return false
        }
    }

    private func suspendInput() async throws {
        input.invalidate() // close gate BEFORE the first suspension
        stats["inputInvalidations", default: 0] += 1
        onInputEpoch?(input.epoch, false)
        // Always await the drain, including when an up is already in flight.
        try await sendWrite(.release)
    }

    func pollCursor() async {
        guard !finished, phase == .streaming else { return }
        do { try await sendSealed(RFB.framebufferUpdateRequest(incremental: true, w: 1, h: 1)) }
        catch { await fail(error) }
    }

    private func enableInput(_ geometry: DesktopGeometry) {
        input.activate(geometry)
        onInputEpoch?(input.epoch, true)
    }

    /// `channel`: tests inject their own; the app always uses the default.
    init(config: SessionConfiguration, password: SecretBytes, pipeline: MediaPipeline, evidence: EvidenceLog,
         channel: ControlChannel? = nil,
         trust: @escaping @Sendable (String, String) async -> Bool,
         onPhase: @escaping @Sendable (SessionPhase, String) -> Void) {
        self.config = config
        self.password = password
        self.channel = channel ?? ControlChannel(host: config.host, port: config.port)
        self.pipeline = pipeline
        self.evidence = evidence
        self.trust = trust
        self.onPhase = onPhase
        let initial = DisplayRequest(viewportPixels: CGSize(width: Double(config.logicalWidth) * config.hidpiScale,
                                                            height: Double(config.logicalHeight) * config.hidpiScale),
                                     profile: config.hidpiScale == 2 ? .retina : .moreSpace)
        desired = initial
        lastRequested = initial
    }

    private func enter(_ p: SessionPhase, _ detail: String = "") {
        phase = p
        evidence.set("session.phase.\(p.rawValue)", ISO8601DateFormatter().string(from: Date()) + (detail.isEmpty ? "" : " \(detail)"))
        onPhase(p, detail)
    }

    // MARK: lifecycle

    /// Runs the session until failure or `disconnect()`.
    func run() async {
        guard !finished else { return }             // disconnected before it started: never connect
        do {
            try await negotiate()
            try await controlLoop()
        } catch {
            if !finished {
                evidence.set("session.failure", "\(phase.rawValue): \(error)")
                enter(.failed, "\(phase.rawValue): \(error)")
                await teardown(releasingInput: false)
            }
        }
    }

    /// A coherent, completely initialized desktop was actually presented.
    /// An old drawable callback cannot complete a newer resize/offer.
    func markPresented(_ p: DesktopPresentation) async {
        guard !finished, phase == .awaitingRandomAccess, p.offerID == currentOffer,
              p.geometry == offeredGeometry, pipeline.isCurrent(generation: p.generation) else { return }
        transitionTimeout?.cancel(); transitionTimeout = nil
        evidence.set("media.presented.offer\(p.offerID)", "generation \(p.generation) \(p.geometry.summary) nanos \(p.nanos)")
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if let r = resizing {
            let elapsed = Double(p.nanos - r.sent) / 1e6
            resizeTimes.append(elapsed)
            evidence.set("resize.result.\(r.id)", "\(p.geometry.summary); offer \(p.offerID) gen \(p.generation); first coherent presentation \(ms(elapsed)) ms")
            evidence.set("resize.timesMs", resizeTimes.map { ms($0) }.joined(separator: ","))
            evidence.set("resize.distributionMs", distribution(resizeTimes))
        }
        #endif
        resizing = nil
        enableInput(p.geometry)
        enter(.streaming)
        do { try await sendResizeIfReady() } catch { await fail(error) }
    }

    /// Latest viewport/profile wins; at most one request remains in flight.
    func requestResize(_ request: DisplayRequest) async {
        guard !finished else { return }
        desired = request
        do { try await sendResizeIfReady() } catch { await fail(error) }
    }

    private func sendResizeIfReady() async throws {
        guard phase == .streaming, input.enabled, resizing == nil, desired != lastRequested else { return }
        try await suspendInput()
        resizeSerial += 1
        let request = desired
        lastRequested = request
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let sent = DispatchTime.now().uptimeNanoseconds
        #else
        let sent: UInt64 = 0                    // read only by the resize latency evidence
        #endif
        resizing = (resizeSerial, request, sent)
        currentOffer = 0
        enter(.resizing, request.summary)
        armTransitionTimeout()
        if let transport { await onMediaQueue { transport.suspend() } }
        guard !finished else { return }
        evidence.set("resize.request.\(resizeSerial)", "\(request.summary); nanos \(resizing!.sent)")
        try await sendSealed(request.message)
    }

    private func armTransitionTimeout() {
        transitionTimeout?.cancel()
        transitionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await self?.transitionExpired()
        }
    }

    private func transitionExpired() async {
        guard !finished, phase != .streaming else { return }
        if let r = resizing { evidence.set("resize.result.\(r.id)", "FAIL: timed out in \(phase.rawValue)") }
        await fail(SessionFailure.adaptiveUnavailable("display transition timed out in \(phase.rawValue); reconnect manually"))
    }

    private func fail(_ error: Error) async {
        guard !finished else { return }
        evidence.set("session.failure", "\(phase.rawValue): \(error)")
        enter(.failed, "\(phase.rawValue): \(error)")
        await teardown(releasingInput: false)
    }

    func disconnect() async {
        guard !finished else { return }
        enter(.disconnecting)
        await teardown()
        enter(.idle)
    }

    private func teardown(releasingInput: Bool = true) async {
        if tearingDown {
            if !releasingInput, !finished {
                // A control failure may arrive while normal teardown awaits
                // the mandatory-release barrier. Abort that queued release too.
                input.discard()
                onInputEpoch?(input.epoch, false)
                finished = true
                abandonWrites()
                await channel.close()
            }
            return
        }
        tearingDown = true
        if releasingInput, records != nil { try? await suspendInput() }
        else {
            // Preserve fail-closed behavior: never emit release records
            // after control authentication/framing failed.
            input.discard()
            onInputEpoch?(input.epoch, false)
        }
        finished = true
        abandonWrites()
        if !releasingInput { await channel.close() }
        cursors = CursorCache()
        onCursor?(nil, false)
        transitionTimeout?.cancel(); transitionTimeout = nil
        password?.wipe(); password = nil
        let transport = self.transport, pipeline = self.pipeline
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pipeline.queue.async {
                transport?.stop()
                pipeline.resetStream()
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                pipeline.publishEvidence()
                #endif
                c.resume()
            }
        }
        self.transport = nil
        await channel.close()
        evidence.set("control.counters", stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        evidence.set("session.teardown", ISO8601DateFormatter().string(from: Date()))
    }

    // MARK: negotiation

    private func negotiate() async throws {
        enter(.connecting, "\(config.host):\(config.port)")
        try await channel.open(timeout: .seconds(45))
        enter(.rfbHandshake)
        guard let password else { throw SessionFailure.protocolViolation("credentials consumed") }
        var transcript = AuthTranscript()
        let authenticator = HPSSAuthenticator(channel: channel, host: config.host, trustOnFirstUse: trust)
        enter(.authenticating)
        let wrapKey: [UInt8]
        do {
            wrapKey = try await authenticator.run(username: config.username, password: password, transcript: &transcript)
        } catch {
            recordAuth(transcript, outcome: "\(error)")
            throw error
        }
        self.password = nil
        // Authentication runs off this actor, so teardown may have begun
        // meanwhile. Its result is then void: nothing more is sent and no
        // session state is created from it.
        guard !finished else {
            recordAuth(transcript, outcome: "M2 verified; discarded: session closed during authentication")
            throw CancellationError()
        }
        recordAuth(transcript, outcome: "accepted; M2 verified")

        // ClientInit / ServerInit.
        try await channel.send([0xC1])
        var si = ByteReader(try await channel.read(24, timeout: .seconds(10), "ServerInit"))
        let sw = try si.u16(), sh = try si.u16()
        try si.skip(16)
        let nameLength = Int(try si.u32())
        guard nameLength <= 4096 else { throw SessionFailure.protocolViolation("ServerInit name length") }
        _ = try await channel.read(nameLength, timeout: .seconds(5), "ServerInit name")
        evidence.set("rfb.serverInit", "\(sw)x\(sh)")
        if let peek = try await channel.peek(4, timeout: .milliseconds(500)), peek == [0x00, 0x4A, 0x00, 0x01] {
            throw SessionFailure.otherConsoleUser
        }

        // Cleartext prelude + display + opening SetEncodings.
        let os = config.osVersion
        let identity = RFB.ViewerIdentity(osVersion: (UInt32(os.0), UInt32(os.1), UInt32(os.2)))
        try await channel.send(RFB.viewerInfo(identity) + RFB.setEncryptionStart)
        evidence.set("rfb.viewerIdentity", "viewer_app=0x\(String(identity.viewerApp, radix: 16)) app=0.1.0 os=\(os.0).\(os.1).\(os.2) (Vicinia; capability bitmap kept)")
        try await Task.sleep(for: .milliseconds(100))
        try await channel.send(lastRequested.message)
        try await channel.send(RFB.setEncodings(RFB.openingEncodings))
        enter(.virtualDisplayReady, "requested \(config.logicalWidth)x\(config.logicalHeight) @\(config.hidpiScale)")

        // Plaintext reply carrying the 1103 rekey (+ possibly media message 1).
        var sawMessage1 = false
        while records == nil {
            let type = try await channel.read(1, timeout: .seconds(10), "plaintext reply")[0]
            switch type {
            case 0x14:
                let head = try await channel.read(3, timeout: .seconds(5), "misc status")
                _ = try await channel.read(Int(head[1]) << 8 | Int(head[2]), timeout: .seconds(5), "misc status body")
            case 0x00:
                let head = try await channel.read(3, timeout: .seconds(5), "update header")
                for _ in 0 ..< (Int(head[1]) << 8 | Int(head[2])) {
                    var rh = ByteReader(try await channel.read(12, timeout: .seconds(5), "rect header"))
                    try rh.skip(8)
                    let enc = try rh.i32()
                    switch enc {
                    case 1103:
                        let rekey = try await channel.read(36, timeout: .seconds(5), "rekey")
                        records = try RecordLayer(rekey: rekey, wrapKey: wrapKey)
                    case 1010, 1011:
                        let n = try await channel.read(2, timeout: .seconds(5), "media size")
                        let body = try await channel.read(Int(n[0]) << 8 | Int(n[1]), timeout: .seconds(5), "media body")
                        if enc == 1010, let m = MediaStreamMessage(body) { if try await noteMedia(m) { sawMessage1 = true } }
                    default:
                        throw SessionFailure.protocolViolation("unexpected plaintext encoding \(enc)")
                    }
                }
            default:
                throw SessionFailure.protocolViolation(String(format: "unexpected plaintext message 0x%02x", type))
            }
        }
        try await channel.send(RFB.setEncryptionToggle)
        enter(.encryptedControl)
        try await sendSealed(RFB.setEncodings(RFB.hpEncodings))

        // Media-init message 1 (ports) must precede the offer.
        enter(.awaitingMediaInit)
        let deadline = ContinuousClock.now + .seconds(3)
        while !sawMessage1 && mediaPorts == nil {
            let left = deadline - ContinuousClock.now
            guard left > .zero, try await channel.awaitData(timeout: left) else { throw SessionFailure.noMediaInit }
            for m in try await readMessages() { if case .media(let mm) = m, mm.kind == 1 { sawMessage1 = true } }
        }
        try await negotiateMedia()
    }

    /// Only called by the control reader, after an actual, unconsumed message 1.
    private func negotiateMedia() async throws {
        guard !finished, let ports = mediaPorts, mediaInitSerial > consumedMediaInit else { throw SessionFailure.noMediaInit }
        consumedMediaInit = mediaInitSerial
        let transport: MediaTransport
        if let existing = self.transport, let boundPorts, boundPorts == ports {
            transport = existing
        } else {
            if let existing = self.transport { await onMediaQueue { existing.stop() } }
            transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: MediaOffer.tilesPerFrame)
            self.transport = transport
            let host = config.host, pipeline = self.pipeline
            try await onMediaQueueThrowing { [weak self] in
                try transport.bind(host: host, audioPort: ports.audio, videoPort: ports.video)
                transport.onLiveness = { event in Task { await self?.mediaLiveness(event) } }
                pipeline.onFailure = { reason in Task { await self?.failMedia(reason) } }
            }
            boundPorts = ports
        }
        try await suspendInput()
        enter(.mediaNegotiating)
        armTransitionTimeout()
        var canvas: (Int, Int)?
        for attempt in 1...2 {
            guard !finished else { return }
            offerSerial += 1
            currentOffer = offerSerial
            let offer = try MediaOffer.make(clientName: config.clientName, hardwareModel: config.hardwareModel,
                                            osBuild: config.osBuild)
            let offerID = currentOffer
            try await onMediaQueueThrowing {
                try transport.configure(keys: offer.keys, videoSSRC: offer.videoSSRC, audioSSRC: offer.audioSSRC, offerID: offerID)
            }
            try await sendSealed(offer.message)
            try await sendSealed(RFB.framebufferUpdateRequest(incremental: false))
            evidence.set("media.offer.\(currentOffer)", "message1 \(consumedMediaInit), attempt \(attempt); 0x1c \(offer.message.count) B, flags 0x\(String(MediaOffer.configFlags, radix: 16)), tiles \(MediaOffer.tilesPerFrame), HEVC bank, audio f4=1000; fresh SRTP contexts")
            canvas = try await awaitAnswer(timeout: .milliseconds(1200))
            if canvas != nil { break }
        }
        guard !finished else { return }
        guard let (cw, ch) = canvas else { throw SessionFailure.noAnswer }
        guard let geometry = layout?.geometry,
              Int(geometry.backing.width) == cw, Int(geometry.backing.height) == ch else {
            throw SessionFailure.adaptiveUnavailable("media canvas disagrees with authoritative single-display layout")
        }
        offeredGeometry = geometry
        let offerID = currentOffer
        enter(.awaitingRandomAccess, "canvas \(cw)x\(ch)")
        let ltrp = answerLTRP.flatMap { $0.offer == offerID ? $0.value : nil } ?? .absent("no answer for this offer")
        await onMediaQueue {
            // The video leg carries HEVC only: MediaTransport drops every other payload type.
            transport.referenceAcknowledgments(answer: ltrp, codec: .hevc, offerID: offerID)
            transport.canvasKnown(width: cw, height: ch, geometry: geometry, offerID: offerID)
            transport.startFeedback()
        }
    }

    private func recordAuth(_ t: AuthTranscript, outcome: String) {
        evidence.set([
            "auth.securityTypes": "\(t.securityTypes)", "auth.hostKeyFingerprint": t.hostKeyFingerprint,
            "auth.pin": t.pinStatus, "auth.iterations": "\(t.iterations)", "auth.options": t.options,
            "auth.challengeFraming": t.challengeFraming, "auth.proofFraming": t.proofFraming,
            "auth.m2Verified": "\(t.m2Verified)", "auth.outcome": outcome, "auth.rejectionWire": t.rejectionWire,
        ])
    }

    private func awaitAnswer(timeout: Duration) async throws -> (Int, Int)? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero, try await channel.awaitData(timeout: left) else { return nil }
            var answered = false, answerCanvas: (Int, Int)?
            for m in try await readMessages() {
                guard case .media(let mm) = m else { continue }
                if mm.kind == 3 { throw SessionFailure.offerRefused(mm.summary) }
                if mm.kind == 2 {
                    answered = true
                    if let c = MediaOffer.canvas(inAnswer: mm.body) { answerCanvas = (c.0, c.1) }
                    evidence.set("media.answer", "\(mm.summary) canvas=\(answerCanvas.map { "\($0.0)x\($0.1)" } ?? "absent")")
                    let ltrp = MediaOffer.videoLTRP(inAnswer: mm.body)       // video blob only, by the answer's lengths
                    answerLTRP = (currentOffer, ltrp)
                    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                    evidence.set("media.answer.ltrp", ltrp.description)
                    #endif
                }
            }
            if answered {
                if let answerCanvas { return answerCanvas }
                if let layout {
                    evidence.set("media.canvasSource", "authoritative display layout (answer carried no canvas; SPS must confirm)")
                    return (layout.backingWidth, layout.backingHeight)
                }
                throw SessionFailure.adaptiveUnavailable("answer without canvas and no display layout")
            }
        }
    }

    // MARK: encrypted control

    private enum Handled { case media(MediaStreamMessage), other }

    // Actor reentrancy permits input, release and negotiation to overlap while
    // Network.framework completes a send. Queue events/messages in call order;
    // one drain preserves both RFB transitions and encrypted record sequence.
    // Seal only at dispatch so obsolete input can be dropped without CBC gaps.
    private var outbound: [(ControlWrite, CheckedContinuation<Void, Error>)] = []
    private var outboundBytes = 0
    private var sending = false
    /// Writes queued behind the one being sent (read-only; used by session tests).
    var pendingWrites: Int { outbound.count }
    private func sendSealed(_ message: [UInt8]) async throws {
        try await sendWrite(.message(message))
    }
    private func sendWrite(_ write: ControlWrite) async throws {
        guard !finished, records != nil else { throw SessionFailure.protocolViolation("record layer inactive") }
        guard outboundBytes + write.queuedByteCount <= 1 << 20 else { throw SessionFailure.protocolViolation("control send backlog") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            outbound.append((write, c)); outboundBytes += write.queuedByteCount
            if !sending {
                sending = true
                Task { await drainOutbound() }
            }
        }
    }
    private func abandonWrites() {
        let abandoned = outbound; outbound.removeAll(); outboundBytes = 0
        for (_, c) in abandoned { c.resume(throwing: ChannelError.closed("session ended")) }
    }
    private func drainOutbound() async {
        while !finished, !outbound.isEmpty {
            let (write, continuation) = outbound.removeFirst()
            outboundBytes -= write.queuedByteCount
            do {
                guard let records else { throw ChannelError.closed("record layer inactive") }
                let buttons = input.buttons, keys = input.keys.count
                // No suspension between epoch validation, ledger mutation and
                // submission: a reentrant transition includes this in-flight send.
                let bytes = try write.seal(records: records, input: &input)
                if case .release = write {
                    evidence.set("input.release", "epoch \(input.epoch) releasedButtons \(buttons) releasedKeys \(keys) recordBytes \(bytes?.count ?? 0) heldButtons \(input.buttons) heldKeys \(input.keys.count)")
                }
                if let bytes { try await channel.send(bytes) }
                else if case .input = write { stats["obsoleteInputDropped", default: 0] += 1 }
                continuation.resume()
            }
            catch {
                continuation.resume(throwing: error)
                let rest = outbound; outbound.removeAll(); outboundBytes = 0
                for (_, c) in rest { c.resume(throwing: error) }
                break
            }
        }
        sending = false
    }

    /// Reads one record (blocking until it is complete) and handles every
    /// message it completes.
    private func readMessages() async throws -> [Handled] {
        guard let records else { throw SessionFailure.protocolViolation("record layer inactive") }
        let lb = try await channel.read(2, timeout: .seconds(30), "record length")
        let n = Int(lb[0]) << 8 | Int(lb[1])
        try RecordLayer.validateLength(n)
        pending += try records.open(try await channel.read(n, timeout: .seconds(10), "record"))
        stats["records", default: 0] += 1
        var out: [Handled] = []
        while !pending.isEmpty {
            // A message may span records and a record may end mid-message: the
            // parser delimits by the message grammar only, or fails explicitly.
            let parsed: ParseResult
            do { parsed = try ServerMessageParser.parse(pending) } catch {
                throw SessionFailure.protocolViolation("\(error)")
            }
            switch parsed {
            case .needMore:
                guard pending.count < ServerMessageParser.maxMessage else {
                    throw SessionFailure.protocolViolation("message exceeds limit")
                }
                return out
            case .complete(let message, let consumed):
                pending.removeFirst(consumed)
                out += try await handle(message)
            }
        }
        return out
    }

    private func handle(_ message: ServerMessage) async throws -> [Handled] {
        switch message {
        case .framebufferUpdate(let rects):
            var out: [Handled] = []
            for r in rects {
                stats["rect.\(r.encoding)", default: 0] += 1
                switch r.encoding {
                case 1010:
                    if let m = MediaStreamMessage(r.body) { _ = try await noteMedia(m); out.append(.media(m)) }
                case 1104:
                    try cursors.consume(r)
                    onCursor?(cursors.selected, cursors.visible)
                    evidence.set("cursor.shape", "\(r.w)x\(r.h) hotspot \(r.x),\(r.y); cache \(cursors.images.count)")
                case 1109:
                    let status = try HostKeyboardStatus(r.body)
                    evidence.set("keyboard.host", "\(status.source); secure=\(status.secure) flags=\(status.flags)")
                case 1105:
                    guard let l = DisplayLayout(r.body), let geometry = l.geometry,
                          l.backingWidth > 0, l.backingHeight > 0 else {
                        throw SessionFailure.adaptiveUnavailable("invalid/multiple display layout; single virtual display required")
                    }
                    try await suspendInput()
                    let changed = layout?.geometry != geometry
                    layout = l
                    let n = stats["rect.1105", default: 0]
                    evidence.set("display.layout", geometry.summary)
                    evidence.set("display.layout.\(n)", "\(geometry.summary); changed \(changed)")
                    // Rearming is independent of media negotiation. An unchanged
                    // layout MUST NOT create an offer; a fresh message 1 can.
                    try await sendSealed(RFB.rearmUpdates(width: l.scaledWidth, height: l.scaledHeight))
                    stats["layoutRearms", default: 0] += 1
                    if !changed, phase == .streaming { enableInput(geometry) }
                    if changed, [.streaming, .awaitingRandomAccess].contains(phase) {
                        currentOffer = 0
                        enter(.hostReconfiguring, geometry.summary)
                        armTransitionTimeout()
                        if let transport { await onMediaQueue { transport.suspend() } }
                    }
                case 1103:
                    try records?.rotate(rekey: r.body)
                    evidence.set("control.rekeys", "\(records?.rekeys ?? 0)")
                default:
                    break                       // bounded ignored metadata
                }
            }
            return out
        case .miscStatus(let command, _):
            stats["misc.\(command.map(String.init) ?? "?")", default: 0] += 1
        case .bell: stats["bell", default: 0] += 1
        case .cutText: stats["cutTextDiscarded", default: 0] += 1
        case .clipboardSend: stats["clipboardDiscarded", default: 0] += 1
        }
        return [.other]
    }

    @discardableResult
    private func noteMedia(_ m: MediaStreamMessage) async throws -> Bool {
        evidence.set("media.message.\(m.kind)", m.summary)
        if let p = m.ports {
            if input.enabled { try await suspendInput() }
            mediaPorts = (p.audio, p.video)
            mediaInitSerial += 1
            return true
        }
        return false
    }

    private func controlLoop() async throws {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        var lastCounters = ContinuousClock.now
        #endif
        while !finished {
            _ = try await readMessages()
            guard !finished else { return }
            if mediaInitSerial > consumedMediaInit {
                // Also covers an actual wake media-init with unchanged geometry.
                if phase == .streaming {
                    currentOffer = 0
                    enter(.hostReconfiguring, "new media-init")
                }
                try await negotiateMedia()
            }
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if ContinuousClock.now - lastCounters > .seconds(2) {
                lastCounters = ContinuousClock.now
                evidence.set("control.counters", stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            }
            #endif
        }
    }

    // MARK: media queue bridging (no blocking of the actor's executor)

    private func onMediaQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pipeline.queue.async { body(); c.resume() }
        }
    }

    private func onMediaQueueThrowing(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pipeline.queue.async { do { try body(); c.resume() } catch { c.resume(throwing: error) } }
        }
    }
}
