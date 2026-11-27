// Vicinia — one live session's Mac audio: authenticated packets from
// MediaTransport → reorder and loss → AAC-ELD decoding → paced buffers on an
// AVAudioPlayerNode → the system output route and volume.
// SPDX-License-Identifier: MIT
//
// Threads: MediaTransport hands packets over on the media queue. Stream state,
// the decoder, graph lifecycle and the AVAudioSession activation belong to
// one process-wide serial audio queue (the AVAudioSession is shared, so one
// session's teardown is ordered before the next session's start). No Vicinia
// code runs on the audio real-time thread: the player node renders the
// buffers scheduled from the queue. Other threads use the bounded ingress
// mailbox and the PCM commit boundary, which also owns the active player stop.

import AVFAudio
import Foundation
import Synchronization

/// The process has one AVAudioSession: the pipeline that activated it last
/// owns it, so an earlier session's late stop cannot deactivate a newer one.
final class AudioSessionOwnership: Sendable {
    static let shared = AudioSessionOwnership()
    private let owner = Mutex<UUID?>(nil)
    func claim(_ claimant: UUID) { owner.withLock { $0 = claimant } }
    /// True when `claimant` owned the session; it no longer does.
    func release(_ claimant: UUID) -> Bool {
        owner.withLock { owner in
            guard owner == claimant else { return false }
            owner = nil
            return true
        }
    }
}

/// The device's AVAudioSession; tests substitute their own.
protocol AudioSessionControlling: Sendable {
    var ownership: AudioSessionOwnership { get }
    func activate() throws
    func deactivate()
    var ioBufferDuration: TimeInterval { get }
    var outputLatency: TimeInterval { get }
    /// Used only to compare output routes, including two ports of the same type.
    var outputRouteIDs: [String] { get }
}

/// Playback category without microphone access or background audio: the
/// system route, volume and silent-mode policy for media apply.
struct SystemAudioSession: AudioSessionControlling {
    var ownership: AudioSessionOwnership { .shared }
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
    func deactivate() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    var ioBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    var outputRouteIDs: [String] { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid) }
}

/// System notifications the pipeline reacts to, parsed where they are posted.
/// iOS 27 reports interruptions as a system deactivation followed, possibly, by
/// a resumption recommendation.
enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool)
    case routeLost, routeChanged
    case mediaServicesLost, mediaServicesReset
    case engineConfigurationChanged

    static let names: [Notification.Name] = [
        AVAudioSession.didBecomeInactiveNotification, AVAudioSession.resumptionRecommendationNotification,
        AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereLostNotification,
        AVAudioSession.mediaServicesWereResetNotification,
    ]

    init?(_ note: Notification) {
        switch note.name {
        case AVAudioSession.didBecomeInactiveNotification:
            // Our own deactivation is not an interruption.
            guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                  context.source == .system else { return nil }
            self = .interruptionBegan
        case AVAudioSession.resumptionRecommendationNotification:
            guard let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return nil }
            self = .interruptionEnded(shouldResume: context.recommendation == .shouldResume)
        case AVAudioSession.routeChangeNotification:
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            self = raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable ? .routeLost : .routeChanged
        case AVAudioSession.mediaServicesWereLostNotification: self = .mediaServicesLost
        case AVAudioSession.mediaServicesWereResetNotification: self = .mediaServicesReset
        case .AVAudioEngineConfigurationChange: self = .engineConfigurationChanged
        default: return nil
        }
    }
}

/// Only the audio worker takes entries, one at a time. Each admission captures
/// the authorization and offer in the same transaction as its reservation.
private struct AudioIngress {
    struct Authorization: Equatable, Sendable {
        let feature: FeatureAuthorization
        let offer: UInt64?
        let revision: UInt64
    }
    struct Entry: Sendable {
        let packet: AudioPacket
        let authorization: Authorization
    }

    // 32 × 10 ms covers a short consumer stall. This is a retention limit,
    // independent of the reorder deadline and the bounded PCM playout target.
    static let packetLimit = 32
    static let byteLimit = packetLimit * HPSSAudio.maxAccessUnitBytes
    private var ring = [Entry?](repeating: nil, count: packetLimit)
    private var head = 0
    private(set) var pending = 0
    private(set) var pendingBytes = 0
    private(set) var inFlightBytes = 0
    private(set) var cancelled = 0
    var drainScheduled = false

    var enabled: Bool
    var terminated = false
    var suspended = false
    var offer: UInt64?
    var feature: FeatureAuthorization?
    var highestOperation: UInt64 = 0
    var revision: UInt64 = 0
    var ready = false

    init(enabled: Bool) { self.enabled = enabled }

    var permission: Authorization? {
        guard enabled, !terminated, !suspended, let feature else { return nil }
        return Authorization(feature: feature, offer: offer, revision: revision)
    }

    mutating func append(_ packet: AudioPacket) -> Bool {
        let size = packet.payload.count
        guard ready, let permission, permission.offer == nil || packet.mediaGeneration == permission.offer,
              pending + (inFlightBytes == 0 ? 0 : 1) < Self.packetLimit,
              pendingBytes + inFlightBytes + size <= Self.byteLimit else { return false }
        ring[(head + pending) % Self.packetLimit] = Entry(packet: packet, authorization: permission)
        pending += 1
        pendingBytes += size
        return true
    }

    mutating func take() -> Entry? {
        guard let entry = ring[head] else { return nil }
        ring[head] = nil
        head = (head + 1) % Self.packetLimit
        pending -= 1
        inFlightBytes = entry.packet.payload.count
        pendingBytes -= inFlightBytes
        return entry
    }

    mutating func finish() { inFlightBytes = 0 }

    mutating func cancelPending() {
        cancelled += pending
        for i in 0..<pending { ring[(head + i) % Self.packetLimit] = nil }
        pending = 0
        pendingBytes = 0
    }
}

/// Invariant (why @unchecked Sendable is sound): every stored `var` is read
/// and written only on `queue`; the decoder is created in `init` and then used
/// only there. Other threads touch only the mutex-protected ingress and commit.
final class AudioPipeline: @unchecked Sendable {
    enum Interruption: String, Sendable { case system, routeLost, mediaServices }
    enum State: Equatable, Sendable {
        case disabled, negotiating, playing, muted
        case interrupted(Interruption)
        case unavailable
        case failed(String)
    }
    /// `.offline` renders only when pulled by `renderOffline` (tests): no hardware.
    enum Output: Sendable { case device, offline }

    struct Counters: Equatable, Sendable {
        var packets = 0, stale = 0, decoded = 0, decodeErrors = 0, scheduled = 0
        var starts = 0, restarts = 0, interruptions = 0, mediaServicesResets = 0, configurationChanges = 0
    }

    /// Audio is enabled by default for new connections.
    static let defaultEnabled = true
    /// The device decodes the host's format (probed once, by decoding).
    static let canDecode: Bool = (try? AACELDDecoder()) != nil
    static let queue = DispatchQueue(label: "it.danielebufarini.vicinia.audio", qos: .userInteractive)
    /// Consecutive undecodable access units (half a second) that make audio fail.
    static let decodeFailureLimit = 50
    /// Silence after which a running stream reads as waiting again.
    static let activityNanos: UInt64 = 500_000_000

    let queue = AudioPipeline.queue
    // Dedicated serial stop queue decoupled from decode on `queue` and from the
    // notification-delivering thread so system stop events unschedule queued PCM
    // without acquiring pcmCommit inside CoreAudio callbacks or waiting for decode.
    let stopQueue = DispatchQueue(label: "it.danielebufarini.vicinia.audio.stop", qos: .userInteractive)
    let avClock = AVClockCorrelator()
    private let makeDecoder: @Sendable () throws -> AACELDDecoder
    private let decodeAccessUnit: @Sendable (AACELDDecoder, Data) throws -> AVAudioPCMBuffer
    private let beforeCommit: (@Sendable () -> Void)?
    private let afterCommitValidation: (@Sendable () -> Void)?
    private let clockSample: (@Sendable () -> AVAudioFramePosition)?
    private let clockHostNanos: (@Sendable () -> UInt64)?
    private let session: any AudioSessionControlling
    private let sessionOwner = UUID()
    private let output: Output
    private let ingress: Mutex<AudioIngress>
    private struct PCMCommit {
        var player: AVAudioPlayerNode?
        var stopSequence: UInt64 = 0
    }
    // Lock order: pcmCommit → ingress. The published player is the only node
    // allowed to receive PCM. Stop and prepared scheduling (nil completion)
    // share the lock. Ingress never calls CoreAudio, observers only post work,
    // and decoder, engine and session startup/teardown never hold pcmCommit.
    private let pcmCommit = Mutex(PCMCommit())
    // System notifications can arrive inside a CoreAudio call. Signal the
    // worker and stop queue without taking either lock on the delivering thread.
    private let pendingSystemStops = Atomic<Int>(0)
    private let systemStopSequence = Atomic<UInt64>(0)
    private let pendingRouteChanges = Atomic<Int>(0)
    private var appliedRevision: UInt64 = 0

    private var enabled: Bool
    private var authorized = false
    private var appliedOffer: UInt64?
    private var muted = false
    private var interruption: Interruption?
    private var mediaServicesAvailable = true
    private var failure: String?
    private var running = false
    private var decoder: AACELDDecoder?
    private let decoderUnavailable: Bool
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var graphInvalidated = false
    private var reorder = AudioReorderBuffer()
    private var playout = PlayoutControl()
    private var scheduledEnd: AVAudioFramePosition = 0
    private var lastScheduled: UInt64 = 0
    private var scheduledAny = false
    private var timelinePrimed = false
    private var outputLatency: Double = 0
    private var outputRouteIDs: [String] = []
    private var consecutiveDecodeErrors = 0
    private var timer: DispatchSourceTimer?
    private var observers: [any NSObjectProtocol] = []
    private var engineObserver: (id: UUID, token: any NSObjectProtocol)?
    private var published: State?
    private var onState: (@Sendable (State) -> Void)?
    private(set) var counters = Counters()

    /// `makeDecoder`: tests substitute a device without the codec.
    init(enabled: Bool = AudioPipeline.defaultEnabled,
         session: any AudioSessionControlling = SystemAudioSession(), output: Output = .device,
         makeDecoder: @escaping @Sendable () throws -> AACELDDecoder = { try AACELDDecoder() },
         decodeAccessUnit: @escaping @Sendable (AACELDDecoder, Data) throws -> AVAudioPCMBuffer = { try $0.decode($1) },
         beforeCommit: (@Sendable () -> Void)? = nil,
         afterCommitValidation: (@Sendable () -> Void)? = nil,
         clockSample: (@Sendable () -> AVAudioFramePosition)? = nil,
         clockHostNanos: (@Sendable () -> UInt64)? = nil) {
        self.enabled = enabled
        self.ingress = Mutex(AudioIngress(enabled: enabled))
        self.session = session
        self.output = output
        self.makeDecoder = makeDecoder
        self.decodeAccessUnit = decodeAccessUnit
        self.beforeCommit = beforeCommit
        self.afterCommitValidation = afterCommitValidation
        self.clockSample = clockSample
        self.clockHostNanos = clockHostNanos
        decoder = try? makeDecoder()
        decoderUnavailable = decoder == nil
        if output == .device { observeSystem() }
    }

    /// Whether this session can play Mac audio at all; otherwise the offer asks for none.
    var canPlay: Bool { !decoderUnavailable }

    /// `handler` runs on the audio queue, once with the current state and then on every change.
    func bind(onState handler: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            onState = handler
            published = nil
            publish()
        }
    }

    // MARK: media queue

    /// An authenticated packet. False when audio accepts nothing now (the caller counts a discard).
    func accept(_ packet: AudioPacket) -> Bool {
        guard (1...HPSSAudio.maxAccessUnitBytes).contains(packet.payload.count) else { return false }
        return ingress.withLock { state in
            guard state.append(packet) else { return false }
            if !state.drainScheduled {
                state.drainScheduled = true
                queue.async { [self] in drainOne() }
            }
            return true
        }
    }

    /// A new media offer: nothing of the previous stream is played after it.
    func mediaGenerationChanged(_ offer: UInt64) {
        avClock.configure(offer: offer)
        transition(keepReady: true, { state in
            if let previous = state.offer, offer <= previous { return false }
            state.offer = offer
            state.suspended = false
            return true
        }) { pipeline in
            pipeline.appliedOffer = offer
            pipeline.reorder.reset()
            pipeline.counters.restarts += 1
            pipeline.flushStream()
            pipeline.reconcile()
        }
    }

    /// Close admission/commit now and flush the player without restarting it.
    /// The engine can be reused when a newer offer arrives.
    func mediaSuspended(offer: UInt64? = nil) {
        let suspendedOffer = offer ?? ingress.withLock { $0.offer }
        transition(keepReady: true, { state in
            guard !state.suspended, state.offer == suspendedOffer else { return false }
            state.suspended = true
            return true
        }) { pipeline in
            pipeline.reorder.reset()
            pipeline.flushStream()
            if !pipeline.running { pipeline.closeIngressIfCurrent() }
            pipeline.publish()
        }
        avClock.suspend(offer: suspendedOffer)
    }

    func mediaStopped(offer: UInt64? = nil) { mediaSuspended(offer: offer) }

    // MARK: controls (any thread; effects happen on the audio queue)

    func authorize(_ authorization: FeatureAuthorization) {
        // Operations only grow: a late or repeated grant cannot re-arm a revoked one.
        transition({ state in
            guard authorization.operation > state.highestOperation else { return false }
            state.highestOperation = authorization.operation
            state.feature = authorization
            return true
        }) { pipeline in
            pipeline.authorized = true
            if pipeline.running { pipeline.stop() }
            pipeline.reconcile()
        }
    }

    /// Closes the gates and stops local PCM before returning. Heavier teardown
    /// stays on the worker, so a parked decoder cannot delay local revocation.
    func revoke() {
        transition({ state in
            guard state.feature != nil else { return false }
            state.feature = nil
            return true
        }) { pipeline in
            pipeline.authorized = false
            pipeline.stop()
        }
    }

    func setEnabled(_ on: Bool) {
        transition({ state in
            guard state.enabled != on else { return false }
            state.enabled = on
            return true
        }) { pipeline in
            pipeline.enabled = on
            if on {
                pipeline.retry()
            } else {
                pipeline.stop()
            }
        }
    }

    func setMuted(_ on: Bool) {
        queue.async { [self] in
            guard !ingress.withLock({ $0.terminated }) else { return }
            muted = on
            pcmCommit.withLock { $0.player?.volume = on ? 0 : 1 }
            publish()
        }
    }

    /// The user resumes after an interruption or a local failure.
    func resume() {
        queue.async { [self] in
            guard !ingress.withLock({ $0.terminated }) else { return }
            retry()
        }
    }

    /// Terminal and idempotent: nothing is accepted or played afterwards.
    func terminate() {
        transition({ state in
            state.terminated = true
            state.feature = nil
            return true
        }) { pipeline in
            pipeline.authorized = false
            pipeline.stop()
            pipeline.removeSystemObservers()
            pipeline.removeGraph()
            pipeline.decoder = nil
            pipeline.onState = nil
        }
    }

    /// Wait for the actual local flush, engine stop and session release. Audio
    /// already rendered into the hardware/route buffer cannot be recalled.
    func stopAndDrain() async {
        terminate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopQueue.async { continuation.resume() }
        }
    }

    /// Publish the new permission and enqueue its effects in the same order
    /// as other controls and ingress. A previous effect can finish cleanup,
    /// but cannot rearm output for a newer revision.
    private func transition(keepReady: Bool = false, _ change: (inout AudioIngress) -> Bool,
                            apply: @escaping @Sendable (AudioPipeline) -> Void) {
        pcmCommit.withLock { commit in
            let changed = ingress.withLock { state in
                guard !state.terminated, change(&state) else { return false }
                if !keepReady { state.ready = false }
                state.cancelPending()
                state.revision += 1
                let revision = state.revision
                queue.async { [self] in
                    appliedRevision = revision
                    apply(self)
                }
                return true
            }
            if changed {
                commit.player?.stop()
                commit.player = nil
            }
        }
    }

    deinit {
        timer?.cancel()
        removeSystemObservers()
        player?.stop()
        engine?.stop()
        let session = self.session, owner = sessionOwner
        queue.async {
            if session.ownership.release(owner) { session.deactivate() }
        }
    }

    // MARK: audio queue

    private var permission: AudioIngress.Authorization? {
        ingress.withLock { $0.revision == appliedRevision ? $0.permission : nil }
    }

    private var canRender: Bool { pendingSystemStops.load(ordering: .sequentiallyConsistent) == 0 }

    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let permission, canRender, interruption == nil, failure == nil, decoder != nil {
            if !running { start(permission) }
            else if let player, pcmCommit.withLock({ $0.player == nil }) { startPlayer(player, permission: permission) }
        } else if running {
            stop()
        } else {
            closeIngressIfCurrent()
        }
        publish()
    }

    private func start(_ authorization: AudioIngress.Authorization, activatingSession: Bool = true) {
        do {
            if graphInvalidated { removeGraph() }
            if activatingSession {
                try session.activate()
                session.ownership.claim(sessionOwner)
            }
            guard canRender, permission == authorization else { stop(); return }
            let (engine, player) = try graph()
            playout.setRoute(ioBufferDuration: session.ioBufferDuration)
            guard canRender, permission == authorization else { stop(); return }
            try engine.start()
            updateOutputLatency()
            outputRouteIDs = session.outputRouteIDs
            reorder.reset()
            flushStream()                             // nothing scheduled earlier survives a start
            guard startPlayer(player, permission: authorization) else { return }
            running = true
            counters.starts += 1
            startTimer()
        } catch {
            if engine != nil { graphInvalidated = true }
            if canRender, permission == authorization { failure = String(localized: "Mac audio could not start on this device.") }
            stop()
        }
    }

    @discardableResult
    private func startPlayer(_ player: AVAudioPlayerNode, permission authorization: AudioIngress.Authorization) -> Bool {
        // The player has no scheduled buffers while it starts. If revoked
        // during the call, it is stopped without ever opening PCM admission.
        guard canRender, permission == authorization else { stop(); return false }
        do {
            player.volume = muted ? 0 : 1
            try player.playAudio()
        } catch {
            player.stop() // Startup owns this empty, unpublished player.
            graphInvalidated = true
            if canRender, permission == authorization { failure = String(localized: "Mac audio could not start on this device.") }
            stop()
            return false
        }
        let armed = pcmCommit.withLock { commit in
            let stopSequence = systemStopSequence.load(ordering: .sequentiallyConsistent)
            return ingress.withLock { state in
                guard pendingSystemStops.load(ordering: .sequentiallyConsistent) == 0,
                      state.permission == authorization else { return false }
                commit.player = player
                commit.stopSequence = stopSequence
                state.ready = true
                return true
            }
        }
        if !armed {
            player.stop() // The empty node was never published, so only this worker can stop it.
            stop()
        }
        return armed
    }

    private func closeIngressIfCurrent() {
        ingress.withLock { state in
            guard state.revision == appliedRevision else { return }
            state.ready = false
            state.cancelPending()
        }
    }

    private func stop(deactivatingSession: Bool = true) {
        closeIngressIfCurrent()
        flushStream()
        engine?.stop()
        if deactivatingSession, session.ownership.release(sessionOwner) { session.deactivate() }
        running = false
        timer?.cancel(); timer = nil
        reorder.reset()
        publish()
    }

    private func graph() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let player { return (engine, player) }
        guard let format = HPSSAudio.pcmFormat() else { throw AACELDDecoder.Failure.unsupported }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        if output == .offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
        engine.attach(player)
        try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        if output == .device {
            let id = UUID()
            let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                               queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.engineObserver?.id == id else { return }
                    self.handle(.engineConfigurationChanged)
                }
            }
            engineObserver = (id, token)
        }
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private func observeSystem() {
        for name in AudioSessionEvent.names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let event = AudioSessionEvent(note), let self else { return }
                self.enqueueSystemEvent(event)
            })
        }
    }

    func enqueueSystemEvent(_ event: AudioSessionEvent) {
        let stopsOutput = event == .routeLost || event == .interruptionBegan || event == .mediaServicesLost
        let changesRoute = event == .routeChanged
        if stopsOutput {
            pendingSystemStops.add(1, ordering: .sequentiallyConsistent)
            let stopSequence = systemStopSequence.add(1, ordering: .sequentiallyConsistent).newValue
            stopQueue.async { [self] in
                stopActivePlayerIfNeeded(forSystemStop: stopSequence)
            }
        }
        if changesRoute { pendingRouteChanges.add(1, ordering: .acquiringAndReleasing) }
        queue.async { [self] in
            if stopsOutput { pendingSystemStops.subtract(1, ordering: .sequentiallyConsistent) }
            defer { if changesRoute { pendingRouteChanges.subtract(1, ordering: .acquiringAndReleasing) } }
            handle(event)
        }
    }

    private func stopActivePlayerIfNeeded(forSystemStop stopSequence: UInt64) {
        pcmCommit.withLock { commit in
            guard commit.player != nil, stopSequence > commit.stopSequence else { return }
            commit.player?.stop()
            commit.player = nil
        }
    }

    private func removeSystemObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        removeEngineObserver()
    }

    private func removeEngineObserver() {
        if let observer = engineObserver { NotificationCenter.default.removeObserver(observer.token) }
        engineObserver = nil
    }

    private func removeGraph() {
        removeEngineObserver()
        player = nil
        engine = nil
        graphInvalidated = false
    }

    /// System audio events (audio queue). Recovery happens only while the
    /// session's authorization and the user's choice still permit playback.
    func handle(_ event: AudioSessionEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ingress.withLock({ $0.terminated }) else { return }
        switch event {
        case .interruptionBegan:
            counters.interruptions += 1
            if interruption == nil, running || (enabled && authorized) { interruption = .system }
        case .interruptionEnded(let shouldResume):
            if interruption == .system, shouldResume { interruption = nil }
        case .routeLost:
            if engine != nil { graphInvalidated = true }
            if enabled, running || interruption == .system || authorized { interruption = .routeLost }
        case .routeChanged:
            playout.setRoute(ioBufferDuration: session.ioBufferDuration)
            let route = session.outputRouteIDs, priorLatency = outputLatency
            updateOutputLatency()
            if route != outputRouteIDs || abs(outputLatency - priorLatency) >= AVClockCorrelator.routeLatencyStep {
                if !running, engine != nil, route != outputRouteIDs { graphInvalidated = true }
                outputRouteIDs = route
                // Reject the last pair from the previous route even if CoreAudio
                // had rendered it with a forward-looking host timestamp.
                let boundary = max(DispatchTime.now().uptimeNanoseconds, playerClock().hostNanos)
                avClock.audioRouteChanged(offer: appliedOffer, after: boundary)
            }
        case .mediaServicesLost:
            mediaServicesAvailable = false
            discardGraph()
        case .mediaServicesReset:
            counters.mediaServicesResets += 1
            mediaServicesAvailable = true
            discardGraph()
            rebuildDecoder()
        case .engineConfigurationChanged:
            guard engine != nil else { break }
            counters.configurationChanges += 1
            graphInvalidated = true
            if running, canRender, let permission, interruption == nil, failure == nil {
                stop(deactivatingSession: false)
                if canRender, self.permission == permission { start(permission, activatingSession: false) }
                else { stop() }
            }
        }
        reconcile()
    }

    /// The system's audio objects are gone. Remove the old graph observer
    /// before releasing the graph, including on repeated resets.
    private func discardGraph() {
        removeEngineObserver()
        decoder = nil
        stop(deactivatingSession: false)
        _ = session.ownership.release(sessionOwner) // the system's session is gone too
        removeGraph()
    }

    private func retry() {
        guard mediaServicesAvailable else { publish(); return }
        interruption = nil
        failure = nil
        if decoder == nil, !decoderUnavailable { rebuildDecoder() }
        reconcile()
    }

    private func rebuildDecoder() {
        guard !decoderUnavailable else { return }
        decoder = try? makeDecoder()
        if decoder == nil { failure = String(localized: "The Mac audio decoder could not be restarted.") }
    }

    private func drainOne() {
        // An already queued drain may precede the control that applies a
        // newly admitted offer. Leave those packets for the next drain.
        let entry = ingress.withLock { $0.revision == appliedRevision ? $0.take() : nil }
        defer {
            ingress.withLock { state in
                state.finish()
                if state.pending > 0 {
                    // Yield to controls between packets, even under sustained load.
                    queue.async { [self] in drainOne() }
                } else {
                    state.drainScheduled = false
                }
            }
        }
        guard let entry else { return }
        receive(entry.packet, authorization: entry.authorization)
    }

    private func receive(_ packet: AudioPacket, authorization: AudioIngress.Authorization) {
        guard running, permission == authorization else { counters.stale += 1; return }
        counters.packets += 1
        for event in reorder.insert(packet, reorderWait: reorderWait) {
            apply(event, ssrc: packet.ssrc, offer: packet.mediaGeneration, authorization: authorization)
        }
    }

    private var reorderWait: UInt64 { UInt64(playout.targetFrames) * 1_000_000_000 / UInt64(HPSSAudio.sampleRate) / 2 }

    private func apply(_ event: AudioReorderBuffer.Event, ssrc: UInt32, offer: UInt64, authorization: AudioIngress.Authorization) {
        // A preceding block may have failed, or a control may have revoked
        // permission while another block from the same batch was decoding.
        guard running, canRender, permission == authorization else { return }
        switch event {
        case .play(let payload, let timestamp, let sequence, let arrival):
            playout.noteArrival(sequence: sequence, arrival: arrival)
            decodeAndSchedule(payload, timestamp: timestamp,
                              ssrc: ssrc, offer: offer, authorization: authorization)
        case .lost:
            break                                           // counted by the reorder buffer
        case .restart:
            counters.restarts += 1
            flushStream()
            if let player { startPlayer(player, permission: authorization) }
        }
    }

    private func flushStream() {
        pcmCommit.withLock { commit in
            commit.player?.stop()
            commit.player = nil
        }
        scheduledEnd = 0
        scheduledAny = false
        timelinePrimed = false
        consecutiveDecodeErrors = 0
        decoder?.reset()
        playout.restartStream()
        avClock.resetAudioProjection(offer: appliedOffer)
    }

    private func decodeAndSchedule(_ payload: Data, timestamp: UInt32,
                                   ssrc: UInt32, offer: UInt64, authorization: AudioIngress.Authorization) {
        guard let decoder, let player else { return }
        let block: AVAudioPCMBuffer
        do {
            block = try decodeAccessUnit(decoder, payload)
            guard permission == authorization else { return }
            consecutiveDecodeErrors = 0
            counters.decoded += 1
        } catch {
            guard permission == authorization else { return }
            counters.decodeErrors += 1
            consecutiveDecodeErrors += 1
            if consecutiveDecodeErrors >= Self.decodeFailureLimit {
                failure = String(localized: "The Mac's audio could not be decoded.")
                reconcile()
            }
            return
        }
        let (now, renderHost) = playerClock()
        let target = AVAudioFramePosition(playout.targetFrames)
        // Pre-roll supplies part of the priming lead. Bound its contribution
        // to the target so the first buffer starts at sample zero or later.
        let playoutNow = max(now, -target)
        let level = timelinePrimed && scheduledEnd > playoutNow ? Int(scheduledEnd - playoutNow) : 0
        let provisionalStart = level == 0 ? playoutNow + target : scheduledEnd
        let avError = pendingRouteChanges.load(ordering: .acquiring) == 0
            ? avClock.audioErrorFrames(offer: offer, ssrc: ssrc, timestamp: timestamp,
                                       now: DispatchTime.now().uptimeNanoseconds, renderHostNanos: renderHost,
                                       playerSample: now, startSample: provisionalStart, outputLatency: outputLatency)
            : nil
        let start: AVAudioFramePosition
        let scheduled: AVAudioPCMBuffer
        let time: AVAudioTime?
        switch playout.decide(level: level, avErrorFrames: avError) {
        case .drop:
            return
        case .prime:
            start = provisionalStart
            scheduled = block
            time = AVAudioTime(sampleTime: start, atRate: HPSSAudio.sampleRate)
        case .play(let adjust):
            start = scheduledEnd
            scheduled = adjust == 0 ? block : (BlockResampler.resample(block, to: Int(block.frameLength) + adjust) ?? block)
            time = nil
        }
        beforeCommit?()
        let committed = pcmCommit.withLock { commit in
            guard commit.player === player, canRender,
                  ingress.withLock({ $0.ready && $0.permission == authorization }) else { return false }
            afterCommitValidation?()
            player.scheduleBuffer(scheduled, at: time, options: [], completionHandler: nil)
            return true
        }
        guard committed else { return }
        timelinePrimed = true
        scheduledEnd = start + AVAudioFramePosition(scheduled.frameLength)
        counters.scheduled += 1
        lastScheduled = DispatchTime.now().uptimeNanoseconds
        scheduledAny = true
        if published != .playing, !muted { publish() }
    }

    /// The player's sample time at its last render cycle, and that cycle's
    /// host time in uptime nanoseconds (0 when not known).
    private func playerClock() -> (sample: AVAudioFramePosition, hostNanos: UInt64) {
        if let clockSample { return (clockSample(), clockHostNanos?() ?? 0) }
        return pcmCommit.withLock { commit in
            guard let player = commit.player, let render = player.lastRenderTime, render.isSampleTimeValid,
                  let time = player.playerTime(forNodeTime: render), time.isSampleTimeValid,
                  time.sampleRate == HPSSAudio.sampleRate else { return (0, 0) }
            let host = render.isHostTimeValid ? UInt64(max(0, AVAudioTime.seconds(forHostTime: render.hostTime)) * 1e9) : 0
            return (time.sampleTime, host)
        }
    }

    private func updateOutputLatency() {
        // Node presentation latency already includes device latency. Use it
        // when larger, without counting the session's hardware latency twice.
        let nodeLatency = pcmCommit.withLock { ($0.player ?? player)?.outputPresentationLatency ?? 0 }
        outputLatency = max(session.outputLatency, nodeLatency)
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func tick(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, let permission else { return }
        if let source = reorder.source {
            for event in reorder.expire(now: now, reorderWait: reorderWait) {
                apply(event, ssrc: source.ssrc, offer: source.generation, authorization: permission)
            }
        }
        publish()
    }

    private var currentState: State {
        if decoderUnavailable { return .unavailable }
        if !enabled { return .disabled }
        if let failure { return .failed(failure) }
        if !mediaServicesAvailable, interruption != .routeLost { return .interrupted(.mediaServices) }
        if let interruption { return .interrupted(interruption) }
        if muted { return .muted }
        if running, scheduledAny, DispatchTime.now().uptimeNanoseconds &- lastScheduled < Self.activityNanos { return .playing }
        return .negotiating
    }

    private func publish() {
        let state = currentState
        guard state != published else { return }
        published = state
        onState?(state)
    }

    // MARK: tests

    /// An independent render can use this graph while the decoder is parked.
    /// Capture it before parking and pull only until the worker is released.
    var offlineEngine: AVAudioEngine? { queue.sync { output == .offline && running ? engine : nil } }

    var pcmCommitIsAvailable: Bool { pcmCommit.withLockIfAvailable { _ in true } ?? false }

    /// Waits for the controls and coalesced ingress submitted so far (tests).
    func sync() {
        while queue.sync(execute: { ingress.withLock { $0.pending > 0 } }) {}
    }

    var state: State? { queue.sync { published } }
    var ingressReservations: (packets: Int, bytes: Int) {
        ingress.withLock { ($0.pending + ($0.inFlightBytes == 0 ? 0 : 1), $0.pendingBytes + $0.inFlightBytes) }
    }
    var snapshot: (counters: Counters, reorder: AudioReorderBuffer.Counters, playout: PlayoutControl.Counters,
                   target: Int, accepting: Bool, running: Bool, playing: Bool, scheduledEnd: AVAudioFramePosition) {
        queue.sync {
            let playing = pcmCommit.withLock { ($0.player ?? player)?.isPlaying == true }
            let accepting = ingress.withLock { $0.ready && $0.permission != nil }
            return (totalCounters, reorder.counters, playout.counters, playout.targetFrames,
                    accepting, running, playing, scheduledEnd)
        }
    }

    private var totalCounters: Counters {
        var total = counters
        total.stale += ingress.withLock { $0.cancelled }
        return total
    }

    /// Offline output only: renders `frames` from the scheduled audio.
    func renderOffline(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        queue.sync {
            guard output == .offline, running, let engine, let format = HPSSAudio.pcmFormat(),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  (try? engine.renderOffline(frames, to: buffer)) == .success else { return nil }
            return buffer
        }
    }
}
