// Vicinia — session controller (MainActor): wires source → pipeline → renderer.
// SPDX-License-Identifier: MIT
//
// Sources: recorded HPSS clip replay or the live protected HPSS session;
// both feed the same pipeline, decoder and renderer.

import Foundation
import Observation
import QuartzCore
import UIKit

struct LiveRequest: Sendable {
    let host: String
    let username: String
    let password: SecretBytes
    /// The saved profile this connection belongs to (nil: a transient identity).
    var profile: ProfileBinding? = nil
    /// The single-session claim taken where the request was made.
    /// nil: the controller claims at start (tests and local tools).
    var claim: LiveSessionSlot.Claim? = nil
}

struct SessionSource: Identifiable, Hashable {
    let id: String
    let clipURL: URL?            // nil and no `live` = viewport measurement only
    var live: LiveRequest? = nil

    static func == (a: SessionSource, b: SessionSource) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct TrustPrompt: Identifiable {
    let id = UUID()
    let host: String
    let fingerprint: String
}

enum DeviceInfo {
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Physical memory footprint of this process (what the system's memory limit is applied to).
    static var footprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
    #endif

    static var osVersion: (Int, Int, Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }
}

@MainActor
@Observable
final class SessionController {
    private(set) var status = "idle"
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private(set) var hud: [String] = []
    #endif

    private(set) var phase: SessionPhase = .idle
    /// True once a live session was started (the end-of-session box applies only then).
    private(set) var wasLive = false
    private var hasPresentedDesktop = false

    var connectionProgress: String? {
        switch phase {
        case .idle: wasLive ? nil : "Preparing the session…"
        case .connecting, .rfbHandshake: "Connecting to the Mac…"
        case .authenticating: "Authenticating with the Mac…"
        case .virtualDisplayReady, .encryptedControl, .awaitingMediaInit, .mediaNegotiating:
            hasPresentedDesktop ? "Updating display… Last complete desktop retained" : "Negotiating the remote display…"
        case .awaitingRandomAccess:
            hasPresentedDesktop ? "Updating display… Last complete desktop retained" : "Waiting for the first desktop picture…"
        case .resizing, .hostReconfiguring:
            // The host can reconfigure while the first desktop is still awaited.
            hasPresentedDesktop ? "Updating display… Last complete desktop retained" : "Negotiating the remote display…"
        case .streaming, .disconnecting, .failed: nil
        }
    }

    var terminalTitle: String? {
        switch phase {
        case .failed: "Session failed"
        case .disconnecting: "Session ended"
        case .idle where wasLive: "Session ended"
        default: nil
        }
    }
    private(set) var profile: DisplayProfile = .retina
    /// Seconds without any media from the Mac while streaming (nil: flowing).
    private(set) var mediaStalledSeconds: Double?
    enum InputOverflowNotice: Equatable {
        case recovering, recovered

        var message: String {
            switch self {
            case .recovering: "Pending input was discarded. Recovering input…"
            case .recovered: "Pending input was discarded. Input is available again."
            }
        }
    }
    private(set) var inputOverflowNotice: InputOverflowNotice?
    /// Mac audio of a live session (nil for local sources).
    private(set) var audioState: AudioPipeline.State?
    private(set) var audioEnabled = AudioPipeline.defaultEnabled
    private(set) var audioMuted = false
    @ObservationIgnored private(set) var audio: AudioPipeline?
    /// Shared clipboard of a live session (nil for local sources).
    private(set) var clipboard: ClipboardBridge?
    /// The explicit Send panel (system paste control) is shown.
    var clipboardSendShown = false
    @ObservationIgnored private let pasteboard: any LocalPasteboard
    /// The app's single-session owner (`.shared` unless a test injects its own).
    @ObservationIgnored let slot: LiveSessionSlot
    @ObservationIgnored private var liveClaim: LiveSessionSlot.Claim?
    /// An HPSSSession exists for `liveClaim`: its teardown, not the phase, frees the slot.
    @ObservationIgnored private var liveSessionCreated = false
    /// This controller disabled the idle timer (a refused request never does).
    @ObservationIgnored private(set) var holdsIdleTimer = false
    @ObservationIgnored private(set) var lifetime: SessionLifetime?
    @ObservationIgnored private var profileBinding: ProfileBinding?
    /// The session's preference snapshot; saved explicitly for its own profile only.
    @ObservationIgnored private(set) var preferences = ProfilePreferences()
    @ObservationIgnored private(set) var sceneState = SceneState()
    @ObservationIgnored private weak var windowScene: UIWindowScene?
    @ObservationIgnored private var hasAttachedScene = false
    @ObservationIgnored private var sceneObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    /// Minimum interval in nanoseconds between clipboard metadata checks.
    static let clipboardCheckInterval: UInt64 = 1_000_000_000
    @ObservationIgnored private var lastClipboardCheck: UInt64?
    /// Read-only, for tests: change-count checks handed to the clipboard bridge.
    @ObservationIgnored private(set) var clipboardChecks = 0
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @ObservationIgnored private var lifecycleEvents: [String] = []
    #endif

    var panEnabled = false
    var trackpad = true
    var keyboardShown = false
    /// Presentation state of the on-demand session toolbar (one per session).
    let toolbar: SessionToolbar
    @ObservationIgnored private weak var inputView: DesktopView?
    /// Live desktop surface currently attached to this session, used to
    /// coordinate radial overlay gesture dependencies with `DesktopView`.
    var desktopView: DesktopView? { inputView }
    @ObservationIgnored private(set) var inputEpoch: UInt64 = 0
    @ObservationIgnored private(set) var inputReady = false
    private struct QueuedInput {
        let event: RemoteInput
        let epoch: UInt64
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let time: TimeInterval
        #endif
    }
    @ObservationIgnored private var inputQueue: [QueuedInput] = []
    @ObservationIgnored private(set) var inputTask: Task<Void, Never>?
    @ObservationIgnored private let channel: ControlChannel?
    @ObservationIgnored private let evidenceOverride: EvidenceLog?
    @ObservationIgnored private let makeAudio: @MainActor (Bool) -> AudioPipeline
    @ObservationIgnored private let protectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var inputRecovery: (id: UUID, session: HPSSSession, epoch: UInt64)?
    @ObservationIgnored private var cursor = CGPoint.zero
    @ObservationIgnored private var cursorInitialized = false
    @ObservationIgnored private var buttonMask: UInt8 = 0 {
        // Pointer lock returns only once no remote button is held.
        didSet { if (oldValue != 0) != (buttonMask != 0) { toolbar.setRemoteButtonHeld(buttonMask != 0) } }
    }
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Plain counters and bounded raw rows; formatted and written off-main by `evidenceFlush`.
    @ObservationIgnored private var inputCounts: [String: Int] = [:]
    @ObservationIgnored private var inputRows: [InputRow] = []
    @ObservationIgnored private var flushTick = 0
    @ObservationIgnored private var hudPresented = (previous: 0, last: 0)
    @ObservationIgnored private var footprint = (first: 0.0, max: 0.0, last: 0.0)

    /// UIKit event → control send completed (software dispatch time; not physical latency).
    struct InputRow: Sendable { let kind: String; let detail: Int; let event: TimeInterval; let sent: UInt64 }
    #endif

    /// Tests may inject the existing control channel and an audio pipeline
    /// with a test output; production keeps its default endpoint and device output.
    init(channel: ControlChannel? = nil, evidence: EvidenceLog? = nil, toolbar: SessionToolbar = SessionToolbar(),
         protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         makeAudio: @escaping @MainActor (Bool) -> AudioPipeline = { AudioPipeline(enabled: $0) },
         pasteboard: (any LocalPasteboard)? = nil, slot: LiveSessionSlot? = nil) {
        self.channel = channel
        self.evidenceOverride = evidence
        self.toolbar = toolbar
        self.makeAudio = makeAudio
        self.protectedDataAvailable = protectedDataAvailable
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.slot = slot ?? .shared
    }

    func escape() {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let now = ProcessInfo.processInfo.systemUptime
        enqueue(.key(0xff1b, true), at: now); enqueue(.key(0xff1b, false), at: now)
        #else
        enqueue(.key(0xff1b, true)); enqueue(.key(0xff1b, false))
        #endif
    }

    private func enqueue(_ event: RemoteInput, at time: TimeInterval = 0) {
        guard inputReady, !stopped, let session else { return }
        if event.isMove, inputQueue.last?.event.isMove == true { inputQueue.removeLast() }
        if inputQueue.count >= 512 {
            // Close admission before cancellation can re-enter this controller.
            // The crossing event and synchronous tail are discarded, never replayed.
            inputReady = false
            inputQueue.removeAll()
            buttonMask = 0
            inputRecovery = (UUID(), session, inputEpoch)
            inputOverflowNotice = .recovering
            inputView?.cancelInput()
        } else {
            switch event {
            case .release, .pointerRelease: break // system cancellation is not ordinary input
            default: if inputOverflowNotice == .recovered { inputOverflowNotice = nil }
            }
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            inputQueue.append(QueuedInput(event: event, epoch: inputEpoch, time: time))
            #else
            inputQueue.append(QueuedInput(event: event, epoch: inputEpoch))
            #endif
        }
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { inputTask = nil }
            while !stopped, let session = self.session {
                // Also service recovery when overflow emptied the queue. This
                // owner finishes any already-popped dispatch before the barrier.
                if let recovery = inputRecovery {
                    let recovered = await recovery.session.releaseInputForOverflow(epoch: recovery.epoch)
                    if inputRecovery?.id == recovery.id {
                        inputRecovery = nil
                        if recovered, !stopped, self.session === recovery.session,
                           inputEpoch == recovery.epoch, phase == .streaming {
                            inputReady = true
                            inputOverflowNotice = .recovered
                        }
                    }
                    continue // an obsolete completion must not erase a newer queue/recovery
                }
                guard !inputQueue.isEmpty else { break }
                let item = inputQueue.removeFirst()
                await session.dispatchInput(item.event, epoch: item.epoch)
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                if inputRows.count < 4096 {
                    let event = item.event
                    var detail = 0
                    if case .buttons(_, let mask) = event { detail = Int(mask) }
                    inputRows.append(InputRow(kind: event.kindName, detail: detail, event: item.time, sent: DispatchTime.now().uptimeNanoseconds))
                }
                #endif
            }
        }
    }

    private func handleInput(_ event: ViewInput) {
        guard inputReady, let t = renderer?.viewportTransform else { return }
        if !cursorInitialized { cursor = CGPoint(x: t.geometry.logical.midX, y: t.geometry.logical.midY); cursorInitialized = true }
        func position(_ p: CGPoint, relative: Bool) -> Bool {
            if relative { return true }
            guard let logical = t.desktopPoint(fromView: p) else { return false }
            cursor = logical; return true
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let kind: String = switch event {
        case .absolute, .relative: "move"
        case .button: "button"
        case .click: "click"
        case .wheel: "wheel"
        case .key: "key"
        case .release: "release"
        case .pointerRelease: "pointerRelease"
        }
        inputCounts[kind, default: 0] += 1
        let time = inputView?.inputEventTime ?? ProcessInfo.processInfo.systemUptime
        func enqueue(_ input: RemoteInput) { self.enqueue(input, at: time) }
        #else
        func enqueue(_ input: RemoteInput) { self.enqueue(input) }
        #endif
        switch event {
        case .absolute(let p):
            guard position(p, relative: false) else { return }; enqueue(.move(cursor))
        case .relative(let d):
            let anchor = t.viewPoint(fromDesktop: cursor)
            // Fixed sensitivity in view points; common inverse handles zoom/scale.
            let rect = t.desktopRect.intersection(t.viewport)
            let view = CGPoint(x: min(rect.maxX - 0.001, max(rect.minX, anchor.x + d.x)),
                               y: min(rect.maxY - 0.001, max(rect.minY, anchor.y + d.y)))
            guard position(view, relative: false) else { return }; enqueue(.move(cursor))
        case .button(let p, let mask, let relative):
            guard position(p, relative: relative) else { return }; buttonMask = mask; enqueue(.buttons(cursor, mask))
        case .click(let p, let mask, let relative):
            guard position(p, relative: relative) else { return }
            enqueue(.buttons(cursor, mask)); enqueue(.buttons(cursor, buttonMask))
        case .wheel(let mask, let count): enqueue(.scroll(cursor, mask, count))
        case .key(let s, let down): enqueue(.key(s, down))
        case .release: buttonMask = 0; enqueue(.release)
        case .pointerRelease: buttonMask = 0; enqueue(.pointerRelease)
        }
        if event.isIntentionalRemoteAction { toolbar.remoteInteraction() } // after the input was queued
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        renderer?.moveCursor(to: cursor, eventTime: time)
        #else
        renderer?.moveCursor(to: cursor)
        #endif
    }
    var trustPrompt: TrustPrompt?
    @ObservationIgnored private var trustContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private(set) var session: HPSSSession?
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @ObservationIgnored private var streamingSince: Date?
    #endif

    @ObservationIgnored private(set) var evidence: EvidenceLog?
    @ObservationIgnored let mailbox = DesktopUpdateMailbox(recordsUpdates: EvidenceLog.measurementEnabled)
    @ObservationIgnored private let stats = RenderStats()
    @ObservationIgnored private(set) var renderer: DesktopRenderer?
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @ObservationIgnored private var replayer: ClipReplayer?
    @ObservationIgnored private var pipeline: MediaPipeline?
    #endif

    @ObservationIgnored private var geometry: ViewportGeometry?
    @ObservationIgnored private var timer: Timer?
    /// Set once by `stop()` (view closed/disconnected): nothing may start afterwards.
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    func attach(_ view: DesktopView) {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let source = evidence ?? evidenceOverride ?? EvidenceLog()
        #else
        let source = evidence ?? evidenceOverride ?? .disabled
        #endif
        evidence = source
        do {
            renderer = try DesktopRenderer(layer: view.metalLayer, mailbox: mailbox, stats: stats, evidence: source)
        } catch {
            phaseChanged(.failed, "Renderer unavailable: \(error)")
            return
        }
        view.onGeometry = { [weak self, weak view] g in
            guard let self else { return }
            view?.cancelInput()
            geometry = g
            renderer?.viewportPixels = g.usefulPixels
            renderer?.displayScale = g.displayScale
            evidence?.set("viewport", g.summary)
            print("[vicinia] viewport \(g.summary)")
            scheduleDisplayChange()
        }
        view.onZoom = { [weak self] factor, previous, current in
            self?.renderer?.changeZoom(by: factor, from: previous, to: current)
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            self?.recordLocalViewport()
            #endif
        }
        view.onPan = { [weak self] delta in
            self?.renderer?.changePan(by: delta)
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            self?.recordLocalViewport()
            #endif
        }
        inputView = view
        view.onWindowSceneChanged = { [weak self, weak view] scene in
            guard let self, let view, self.inputView === view else { return }
            self.updateWindowScene(scene)
        }
        view.onKeyboardShown = { [weak self] shown in self?.keyboardShown = shown }
        view.onInput = { [weak self] event in self?.handleInput(event) }
        view.onToolbarToggle = { [weak self] in self?.toolbar.toggle(at: nil) }
        view.onToolbarToggleAt = { [weak self] point in self?.toolbar.toggle(at: point) }
        renderer?.onPresented = { [weak self] presentation in
            Task { @MainActor in
                guard let self, !self.stopped, let session = self.session else { return }
                await session.markPresented(presentation)
            }
        }
    }

    func setProfile(_ value: DisplayProfile) {
        profile = value
        scheduleDisplayChange()
    }

    func fit() {
        renderer?.fit()
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        recordLocalViewport()
        #endif
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private func recordLocalViewport() {
        guard let t = renderer?.viewportTransform else { return }
        evidence?.set("viewport.local", "zoom \(t.zoom) pan \(t.pan.x),\(t.pan.y); no remote resize requested")
    }
    #endif

    private func scheduleDisplayChange() {
        resizeTask?.cancel()
        guard !stopped, let geometry, !geometry.usefulPixels.isEmpty else { return }
        let request = DisplayRequest(viewportPixels: geometry.usefulPixels.size, profile: profile)
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !stopped, let session else { return }
            await session.requestResize(request)
        }
    }

    func start(_ source: SessionSource, window: UIWindow?) {
        guard !stopped, phase != .failed else {         // closed before deferred start, or renderer unavailable
            if let reserved = source.live?.claim { slot.finish(reserved) } // reserved for a session that never starts
            return
        }
        if let live = source.live {
            // One live session per app, enforced here, before any side
            // effect: the request's own claim must still be the live one.
            let claim = if let reserved = live.claim { slot.holds(reserved) ? reserved : nil } else { slot.claim() }
            guard let claim else {
                wasLive = true
                phaseChanged(.failed, String(localized: "Another Mac session is open in another window. Close it there before connecting here."))
                return
            }
            liveClaim = claim
        }
        UIApplication.shared.isIdleTimerDisabled = true
        holdsIdleTimer = true
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let log = evidenceOverride ?? EvidenceLog(name: source.live.map { "live-\($0.host)" }
                              ?? source.clipURL?.deletingPathExtension().lastPathComponent ?? "viewport")
        if let previous = evidence { log.set(previous.snapshotForMerge()) }
        evidence = log
        renderer?.rebind(evidence: log)
        #else
        evidence = evidenceOverride ?? .disabled
        #endif
        renderer?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteSceneEvent("memoryWarning") }
        })
        #endif
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.toolbar.assistiveTechnologyChanged() }
            })
        }
        let protected: [(Notification.Name, SceneSignal)] = [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, .protectedDataWillBecomeUnavailable),
            (UIApplication.protectedDataDidBecomeAvailableNotification, .protectedDataDidBecomeAvailable),
        ]
        for (name, signal) in protected {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneSignal(signal) }
            })
        }
        if !protectedDataAvailable() { sceneState.apply(.protectedDataWillBecomeUnavailable) }
        updateWindowScene(window?.windowScene)
        if let live = source.live {
            startLive(live)
            return
        }
        toolbar.sessionEstablished(offeringHint: false) // local replay/measurement: no connection to wait for
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        guard let url = source.clipURL else {
            status = "viewport measurement"
            return
        }
        status = "loading \(url.lastPathComponent)"
        let rule = UserDefaults.standard.string(forKey: "stripe-rule").flatMap(StripeLayout.Rule.init(rawValue:))
        let loop = UserDefaults.standard.object(forKey: "loop") == nil || UserDefaults.standard.bool(forKey: "loop")
        let mailbox = self.mailbox
        Task.detached(priority: .userInitiated) {
            do {
                let clip = try HPSSClip.load(url)
                let pipeline = MediaPipeline(ssrcToStripe: clip.ssrcToStripe,
                                             canvas: clip.canvas, ruleOverride: rule,
                                             mailbox: mailbox, evidence: log)
                log.set([
                    "clip.name": clip.name, "clip.bytes": "\(clip.byteCount)",
                    "clip.packets": "\(clip.packets.count)",
                    "clip.durationSeconds": String(format: "%.2f", clip.durationSeconds),
                    "clip.meta": clip.meta, "clip.ssrcToStripe": "\(clip.ssrcToStripe.sorted { $0.value < $1.value })",
                    "clip.canvas": clip.canvas.map { "\($0.width)x\($0.height)" } ?? "absent",
                    "clip.declaredStripes": clip.declaredStripes.map(String.init) ?? "absent",
                    "clip.events": "\(clip.events.count)",
                    "clip.stripeRuleOverride": rule?.rawValue ?? "none",
                ])
                let replayer = ClipReplayer(clip: clip, pipeline: pipeline, loop: loop)
                await MainActor.run {
                    guard !self.stopped else { return }
                    self.pipeline = pipeline
                    self.replayer = replayer
                    self.status = "replaying \(clip.name) (\(String(format: "%.1f", clip.durationSeconds)) s, loop \(loop))"
                    replayer.start()
                }
            } catch {
                log.set("clip.loadError", "\(error)")
                await MainActor.run { self.status = "clip error: \(error)" }
            }
        }
        #endif
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // Feature effects end before anything else; the input release and the
        // teardown below are unchanged.
        lifetime?.end(.voluntaryClose)
        clipboardSendShown = false
        toolbar.sessionEnded()
        inputReady = false
        inputRecovery = nil
        inputOverflowNotice = nil
        inputQueue.removeAll()
        buttonMask = 0
        inputView?.cancelInput()
        startTask?.cancel()                             // pending startup: no late connection
        startTask = nil
        resizeTask?.cancel(); resizeTask = nil
        timer?.invalidate()
        timer = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        removeSceneObservers()
        renderer?.stop()
        resolveTrust(false)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let flush = evidenceFlush()
        #endif
        let claim = liveClaim, slot = self.slot
        if let claim { slot.beginTeardown(claim) }
        if let session {
            self.session = nil
            Task {
                await session.disconnect()
                if let claim { slot.finish(claim) }   // teardown complete: a successor may bind media
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                flush()
                #endif
            }
        } else {
            if let claim { slot.finish(claim) }       // no session was created
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if let replayer { replayer.stop(then: flush) }
            else { flush() }
            #endif
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        replayer = nil
        pipeline = nil
        #endif
        // A refused request never took the idle timer from the live session.
        if holdsIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func tick() {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        // Scripted physical tests: `-autodisconnect <s>` = normal teardown after s seconds of streaming.
        if phase == .streaming {
            if streamingSince == nil { streamingSince = Date() }
            let limit = UserDefaults.standard.double(forKey: "autodisconnect")
            if limit > 0, let since = streamingSince, Date().timeIntervalSince(since) >= limit, session != nil {
                evidence?.set("session.autodisconnect", "after \(limit) s of streaming")
                status = "disconnected automatically after \(Int(limit)) s"
                stop()
                return
            }
        }
        #endif
        if let session, phase == .streaming { Task { await session.pollCursor() } }
        checkLocalClipboard(at: DispatchTime.now().uptimeNanoseconds)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        // Main run loop: counters and short strings only. Distributions, JSON
        // and file I/O run on the evidence queue, once a second.
        flushTick += 1
        if flushTick % 2 == 0 {
            if let mb = DeviceInfo.footprintMB {            // one syscall a second; growth is judged from first/max/last
                footprint = (footprint.first == 0 ? mb : footprint.first, max(footprint.max, mb), mb)
                let f = footprint
                evidence?.deferred { $0.set("memory.footprintMB", String(format: "first %.1f max %.1f last %.1f", f.first, f.max, f.last)) }
            }
            pipeline?.queue.async { [pipeline] in pipeline?.publishEvidence() }
            evidenceFlush()()
        }
        let v = stats.counters
        let lastSecond = v.newDesktopsPresented - hudPresented.previous     // two 0.5 s ticks
        hudPresented = (hudPresented.last, v.newDesktopsPresented)
        let e = evidence
        evidence?.set("pointer.locked", String(inputView?.window?.windowScene?.pointerLockState?.isLocked ?? false))
        hud = [
            "Vicinia — \(status)",
            "Session: \(phase.rawValue)  host key \(e?.value("auth.hostKeyFingerprint")?.prefix(16) ?? "-")",
            "HW decode: required=\(e?.value("decoder.requireHardwareAcceleratedVideoDecoder") ?? "-") "
                + "using=\(e?.value("decoder.usingHardwareAcceleratedVideoDecoder") ?? "-")",
            "Output: \(e?.value("output.pixelFormat") ?? "-") \(e?.value("output.size") ?? "") "
                + "444=\(e?.value("output.chroma444FullResolution") ?? "-")",
            "Display: \(e?.value("display.layout") ?? e?.value("layout") ?? "-")"
                + (geometry.map { DisplayRequest(viewportPixels: $0.usefulPixels.size, profile: profile).proportional } == true
                   ? " — proportional fit within host bounds" : ""),
            "New desktops presented: \(v.newDesktopsPresented) (\(lastSecond)/s)  ticks \(v.displayTicks)",
            "Viewport: \(geometry?.summary ?? "-")",
            "Keyboard: \(e?.value("keyboard.host") ?? "unknown")  pointer lock \(e?.value("pointer.locked") ?? "unknown")",
            "Audio: \(audioState.map { "\($0)" } ?? "-")",
        ]
        #endif
    }

    private func startLive(_ request: LiveRequest) {
        wasLive = true
        phase = .connecting
        status = "preparing display"
        guard let log = evidence else { return }
        let mailbox = self.mailbox
        startTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                if let g = geometry, g.interfaceOrientation.hasPrefix("landscape") { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled, !stopped else { return }
            // A predecessor still tearing down owns the fixed media ports: wait,
            // bounded; a teardown that does not complete is an explicit failure.
            let predecessorsDone = await slot.awaitPredecessors()
            guard !Task.isCancelled, !stopped else { return }
            startTask = nil
            guard predecessorsDone else {
                phaseChanged(.failed, String(localized: "The previous Mac session is still closing. Try again in a moment."))
                return
            }
            guard let g = geometry else {
                phaseChanged(.failed, "Display setup is unavailable.")
                return
            }
            let display = DisplayRequest(viewportPixels: g.usefulPixels.size, profile: profile)
            let audio = startAudio(request.profile)
            let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: mailbox,
                                         evidence: log, avClock: audio.avClock)
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            self.pipeline = pipeline
            #endif
            var config = SessionConfiguration(
                host: request.host, username: request.username,
                logicalWidth: display.logicalWidth, logicalHeight: display.logicalHeight, hidpiScale: Double(profile.scale),
                hardwareModel: DeviceInfo.machine, osBuild: DeviceInfo.osBuild, osVersion: DeviceInfo.osVersion)
            // Requested whenever this device can play it: switching audio on or off
            // in the session then needs no new offer, which would interrupt video and input.
            config.audio = audio.canPlay ? .requested : .suppressed
            log.set("session.request", "\(request.host) \(display.summary)")
            let session = HPSSSession(
                config: config, password: request.password, pipeline: pipeline, evidence: log, channel: channel, audio: audio,
                trust: { [weak self] host, fingerprint in
                    await self?.askTrust(host: host, fingerprint: fingerprint) ?? false
                },
                onPhase: { [weak self] phase, detail in
                    Task { @MainActor in self?.phaseChanged(phase, detail) }
                })
            self.session = session
            liveSessionCreated = true
            let clipboard = startClipboard(session)
            let claim = liveClaim, slot = self.slot
            Task { [weak self, weak clipboard, session] in
                await session.bindClipboard { [weak clipboard] event in
                    Task { @MainActor in clipboard?.handle(event) }
                }
                await session.bindInput(epoch: { [weak self, weak session] epoch, ready in
                    Task { @MainActor in
                        guard let self, let session, !self.stopped, self.session === session,
                              epoch >= self.inputEpoch else { return }
                        if ready, [.idle, .disconnecting, .failed].contains(self.phase) { return }
                        if ready, self.inputRecovery?.epoch == epoch { return }
                        self.inputRecovery = nil
                        self.inputEpoch = epoch; self.inputReady = ready
                        self.inputQueue.removeAll(); self.buttonMask = 0
                        if ready, self.inputOverflowNotice != nil { self.inputOverflowNotice = .recovered }
                        if !ready { self.inputView?.cancelInput(); self.cursorInitialized = false }
                    }
                }, cursor: { [weak self] image, visible in
                    Task { @MainActor in self?.renderer?.setCursor(image, visible: visible) }
                })
                await session.bindMediaStall { [weak self] seconds in
                    Task { @MainActor in
                        guard let self, self.phase == .streaming || seconds == nil else { return }
                        self.mediaStalledSeconds = seconds
                    }
                }
                await session.run()
                await session.awaitTeardown()
                if let claim { slot.finish(claim) }     // also after a failure, without waiting for Close
            }
        }
    }

    private func phaseChanged(_ p: SessionPhase, _ detail: String) {
        phase = p
        if [.idle, .disconnecting, .failed].contains(p) {
            lifetime?.end(.sessionEnded)
            clipboardSendShown = false
            if let liveClaim {
                slot.beginTeardown(liveClaim)                  // freed once teardown completes
                if !liveSessionCreated { slot.finish(liveClaim) } // failed before any session: nothing to tear down
            }
            inputReady = false
            inputRecovery = nil
            inputQueue.removeAll()
            inputOverflowNotice = nil
            toolbar.sessionEnded()
        }
        if p != .streaming { mediaStalledSeconds = nil }
        if p == .streaming {
            // Successful establishment = the first presented desktop of this session.
            if !hasPresentedDesktop, !stopped {
                toolbar.sessionEstablished(offeringHint: wasLive)
                profileBinding?.recordSuccessfulConnection()
                lifetime?.sessionEstablished()
            }
            hasPresentedDesktop = true
            scheduleDisplayChange()
        }
        if p == .idle, status.hasPrefix("disconnected") { return }       // keep the reason
        status = detail.isEmpty ? p.rawValue : "\(p.rawValue): \(detail)"
        print("[vicinia] session \(status)")
    }

    // MARK: Mac audio and session lifetime

    /// One lifetime and one audio pipeline per live session; audio is
    /// registered with the lifetime, so every revocation stops and flushes it.
    private func startAudio(_ binding: ProfileBinding?) -> AudioPipeline {
        profileBinding = binding
        preferences = binding?.preferences ?? ProfilePreferences()
        audioEnabled = preferences.audio?.enabled ?? AudioPipeline.defaultEnabled
        let lifetime = SessionLifetime(profileID: binding?.profileID ?? UUID(), scene: sceneState)
        let audio = makeAudio(audioEnabled)
        let clock = audio.avClock
        renderer?.onVideoPresented = { clock.videoPresented(offer: $0, generation: $1, timestamp: $2, nanos: $3) }
        audio.bind { [weak self, weak audio] state in
            DispatchQueue.main.async {
                guard let self, let audio, self.audio === audio, !self.stopped else { return }
                self.audioState = state
            }
        }
        lifetime.register("audio", grant: { audio.authorize($0) },
                          revoke: { _ in audio.revoke() }, end: { audio.terminate() })
        self.lifetime = lifetime
        self.audio = audio
        return audio
    }

    /// Plays or stops the Mac's audio in this session and saves the choice for this Mac.
    func setAudioEnabled(_ on: Bool) {
        guard audio != nil, !stopped else { return }
        audioEnabled = on
        audio?.setEnabled(on)
        preferences.audio = AudioPreference(enabled: on)
        profileBinding?.save(preferences)
    }

    // MARK: shared clipboard

    /// One bridge per live session, registered with the lifetime like audio:
    /// grants open the session's accessory gate, every revocation closes it
    /// first (nothing more is sealed), then drops queued clipboard writes.
    private func startClipboard(_ session: HPSSSession) -> ClipboardBridge? {
        guard let lifetime else { return nil }
        let gate = session.accessoryGate
        let local = pasteboard
        let bridge = ClipboardBridge(
            automaticSync: preferences.clipboard?.automaticSync ?? ClipboardBridge.defaultAutomaticSync,
            pasteboard: local,
            send: { [weak session] message, authorization in
                await session?.sendAccessory(message, token: authorization.accessoryToken, producer: .clipboard) ?? .unavailable
            },
            saveAutomaticSync: { [weak self] on in self?.saveClipboardPreference(on) },
            automaticReadAllowed: { [weak self] in self?.clipboardReadAllowed ?? false })
        lifetime.register("clipboard", grant: { authorization in
            gate.grant(authorization.accessoryToken)
            bridge.grant(authorization)
        }, revoke: { [weak session] reason in
            gate.revoke()
            bridge.revoke(reason)
            Task { await session?.purgeAccessories() }
        }, end: { [weak session] in
            gate.revoke()
            bridge.end()
            Task { await session?.purgeAccessories() }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification,
                                                                         object: nil, queue: .main) { [weak self, weak bridge] _ in
            MainActor.assumeIsolated {
                // Only the active scene may read through its current bridge.
                guard let self, let bridge, self.clipboard === bridge, self.clipboardReadAllowed else { return }
                bridge.localPasteboardChanged()
            }
        })
        clipboard = bridge
        return bridge
    }

    /// An automatic clipboard read may start only while this
    /// session runs and its scene is active: never while inactive (Control
    /// Center, the paste prompt), in the background, locked or after the end.
    private var clipboardReadAllowed: Bool { !stopped && sceneState.activity == .active }

    private func saveClipboardPreference(_ on: Bool) {
        preferences.clipboard = ClipboardPreference(automaticSync: on)
        profileBinding?.save(preferences)
    }

    /// Another app can advance the pasteboard change count without notifying
    /// this scene. Check the metadata from the session timer at most once a
    /// second, and only while automatic sending could act. The bridge compares
    /// the change count before reading content, so an unchanged clipboard
    /// needs no programmatic read or permission prompt.
    private func checkLocalClipboard(at now: UInt64) {
        guard !stopped, sceneState.activity == .active,
              let clipboard, clipboard.isAuthorized, clipboard.automaticSync else { return }
        if let lastClipboardCheck, now &- lastClipboardCheck < Self.clipboardCheckInterval { return }
        lastClipboardCheck = now
        clipboardChecks += 1
        clipboard.localPasteboardChanged()
    }

    /// Send local: shows the system paste control, which needs no paste permission.
    func presentClipboardSend() {
        guard clipboard != nil, !stopped else { return }
        clipboardSendShown = true
    }

    func sendClipboard(_ providers: [NSItemProvider]) {
        clipboardSendShown = false
        guard !stopped else { return }
        clipboard?.sendManual(providers)
    }

    /// Receive current Mac.
    func receiveClipboard() {
        guard !stopped else { return }
        clipboard?.receiveManual()
    }

    /// Automatic sync for this session, saved for this Mac.
    func setClipboardAutomaticSync(_ on: Bool) {
        guard !stopped else { return }
        clipboard?.setAutomaticSync(on)
    }

    /// Silences playback for this session only; the stream and its timing continue.
    func setAudioMuted(_ on: Bool) {
        guard audio != nil, !stopped else { return }
        audioMuted = on
        audio?.setMuted(on)
    }

    /// After an interruption or a local audio failure.
    func resumeAudio() {
        guard !stopped else { return }
        audio?.resume()
    }

    /// The view may attach after start, detach or move to another scene.
    /// App notifications are a temporary fallback before the first attachment.
    func updateWindowScene(_ scene: UIWindowScene?) {
        guard !stopped else { return }
        removeSceneObservers()
        windowScene = scene
        hasAttachedScene = hasAttachedScene || scene != nil
        let activity: SceneActivity
        if let scene { activity = SceneActivity(scene.activationState) }
        else if hasAttachedScene { activity = .background }
        else {
            switch UIApplication.shared.applicationState {
            case .active: activity = .active
            case .inactive: activity = .inactive
            default: activity = .background
            }
        }
        // Only protected-data availability can clear an observed lock.
        sceneState = SceneState(activity, protectedDataAvailable: !sceneState.locked)
        propagateScene()
        guard scene != nil || !hasAttachedScene else { return }
        let signals: [(Notification.Name, SceneSignal)] = scene != nil ? [
            (UIScene.willDeactivateNotification, .willDeactivate), (UIScene.didEnterBackgroundNotification, .didEnterBackground),
            (UIScene.willEnterForegroundNotification, .willEnterForeground), (UIScene.didActivateNotification, .didActivate),
        ] : [
            (UIApplication.willResignActiveNotification, .willDeactivate), (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground), (UIApplication.didBecomeActiveNotification, .didActivate),
        ]
        for (name, signal) in signals {
            sceneObservers.append(NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self, weak scene] _ in
                MainActor.assumeIsolated {
                    guard let self, self.windowScene === scene, scene != nil || !self.hasAttachedScene else { return }
                    self.sceneSignal(signal)
                }
            })
        }
    }

    private func removeSceneObservers() {
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        sceneObservers.removeAll()
    }

    private func propagateScene() {
        let active = sceneState.activity == .active
        mailbox.setDisplayActive(active)
        toolbar.setSceneActive(active)
        lifetime?.updateScene(sceneState)
    }

    /// Classification only here: transient inactivity changes nothing, true
    /// background or device lock revokes, a return to active re-authorizes a
    /// session that is still valid.
    func sceneSignal(_ signal: SceneSignal) {
        guard !stopped else { return }
        sceneState.apply(signal)
        propagateScene()
        // A copy made in another app while this window stayed visible: read
        // after this activation callback returns (the read may show a system prompt).
        if signal == .didActivate, let clipboard {
            Task { @MainActor [weak self, weak clipboard] in
                // Recheck the bridge and scene after deferring the activation callback.
                guard let self, let clipboard, self.clipboard === clipboard, self.clipboardReadAllowed else { return }
                clipboard.localPasteboardChanged()
            }
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        switch signal {
        case .willDeactivate: noteSceneEvent("resignActive")
        case .didEnterBackground: noteSceneEvent("background")
        case .willEnterForeground: noteSceneEvent("foreground")
        case .didActivate: noteSceneEvent("active")
        default: break
        }
        #endif
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private func noteSceneEvent(_ label: String) {
        guard lifecycleEvents.count < 64 else { return }
        lifecycleEvents.append("\(label)@\(DispatchTime.now().uptimeNanoseconds)")
        evidence?.set("lifecycle.events", lifecycleEvents.joined(separator: " "))
    }
    #endif

    func askTrust(host: String, fingerprint: String) async -> Bool {
        guard !stopped else { return false }            // the view is gone: never prompt, never trust
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            trustContinuation = c
            trustPrompt = TrustPrompt(host: host, fingerprint: fingerprint)
            print("[vicinia] host key verification shown")
        }
    }

    func resolveTrust(_ accepted: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: accepted)
        trustContinuation = nil
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Captures the main-actor counters by value and returns the work that
    /// summarises, appends the raw trace and writes the file; that work always
    /// runs on the evidence queue, in order with every other evidence update.
    private func evidenceFlush() -> @Sendable () -> Void {
        guard let log = evidence, let output = log.output else { return {} }
        let stats = self.stats, mailbox = self.mailbox
        let counts = inputCounts, rows = inputRows
        inputRows.removeAll(keepingCapacity: true)
        return {
            log.deferred { log in
                log.set(Dictionary(uniqueKeysWithValues: counts.map { ("input.ui." + $0.key, String($0.value)) }))
                Self.writeRenderEvidence(stats: stats, mailbox: mailbox, inputRows: rows, traceURL: output.traceURL, into: log)
                log.write()
            }
        }
    }

    /// Evidence queue only.
    nonisolated private static func writeRenderEvidence(stats: RenderStats, mailbox: DesktopUpdateMailbox,
                                                        inputRows: [InputRow], traceURL: URL, into log: EvidenceLog) {
        let (c, fresh, v) = stats.collect()
        // Raw rows: U = desktop update, C = cursor (`CursorSample`), I = input (outcome = kind,
        // members = button mask, arrival = UIKit event, commit = control send completed).
        log.appendTrace(mailbox.drainRecords().map(\.csv)
            + fresh.cursor.map(\.csv)
            + inputRows.map { "I,\($0.kind),,,,\($0.detail),,,\(UInt64($0.event * 1e9)),,,,,\($0.sent),,,,," })
        let intervals = zip(v.presentedTimes.dropFirst(), v.presentedTimes).map { ($0 - $1) * 1000 }
        var rate = "n/a"
        if let f = v.presentedTimes.first, let l = v.presentedTimes.last, l > f {
            rate = String(format: "%.2f", Double(v.presentedTimes.count - 1) / (l - f))
        }
        let refresh = percentile(v.refreshIntervals, 50).map { String(format: "%.2f Hz", 1 / $0) } ?? "n/a"
        let m = mailbox.counters
        log.set([
            "present.newDesktops": "\(c.newDesktopsPresented)",
            "present.newDesktopsPerSecond": rate,
            "present.repeatedUpdatePresentations": "\(c.repeatedUpdatePresentations)",
            "present.obsoleteSnapshotsDropped": "\(c.obsoleteSnapshotsDropped)",
            "present.intervalMs": distribution(intervals),
            "present.decoderSubmitToPresentMs": distribution(v.submitToPresentMs),
            "present.arrivalToPresentMs": distribution(v.arrivalToPresentMs),
            "present.displayTicks": "\(c.displayTicks)",
            "present.medianRefresh": refresh,
            "present.skippedGPUBusy": "\(c.skippedGPUBusy)",
            "present.lateDrawsMissed": "\(c.lateDrawsMissed)",
            "present.withoutPresentedTime": "\(c.presentationsWithoutTime)",
            "present.replacedWhileWaiting": "\(c.replacedWhileWaiting)",
            "present.supersededBeforePresent": "\(m.supersededUnpresented)",
            "present.heldForPacing": "\(m.heldForPacing)",
            "cursor.eventToPresentMs": distribution(v.cursor.map { ($0.presented - $0.event) * 1000 }),
            "cursor.drawsWithoutPresentedTime": "\(c.cursorDrawsWithoutTime)",
            "cursor.eventToHandledMs": distribution(v.cursor.map { Double($0.handled) / 1e6 - $0.event * 1000 }),
            "cursor.handledToDrawMs": distribution(v.cursor.map { Double($0.draw &- $0.handled) / 1e6 }),
            "cursor.drawToPresentMs": distribution(v.cursor.map { $0.presented * 1000 - Double($0.draw) / 1e6 }),
            "cursor.movesMergedIntoAFrame": "\(v.cursor.filter { $0.moves > 1 }.count) of \(v.cursor.count) frames; superseded positions \(v.cursor.reduce(0) { $0 + $1.moves - 1 })",
            "updates.voidedByReset": "\(m.voidedByReset)",
            "updates.pendingMax": "\(m.pendingUpdatesMax)",
            "trace.recordsDropped": "\(m.recordsDropped)",
            "trace.file": traceURL.lastPathComponent,
            "present.staleGenerationCallbacks": "\(m.staleGenerationDrops)",
            "present.failedStripes": "\(m.failedStripes)",
            "updates.committedUnique": "\(m.committedUnique)",
            "updates.committedPartial": "\(m.committedPartial)",
            "updates.splitCommits": "\(m.splitCommits)",
            "updates.discardedIncomplete": "\(m.discardedIncomplete)",
            "updates.orphanedStripes": "\(m.orphanedStripes)",
            "updates.lateStripes": "\(m.lateStripes)",
            "updates.initialCoverageWaits": "\(m.initialCoverageWaits)",
        ])
    }
    #endif
}

#if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
private extension EvidenceLog {
    func snapshotForMerge() -> [String: String] {
        var out: [String: String] = [:]
        for k in ["metal.device", "viewport"] { if let v = value(k) { out[k] = v } }
        return out
    }
}
#endif
