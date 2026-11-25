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
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
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

    /// Tests may inject the existing control channel; production keeps its default endpoint.
    init(channel: ControlChannel? = nil, evidence: EvidenceLog? = nil, toolbar: SessionToolbar = SessionToolbar()) {
        self.channel = channel
        self.evidenceOverride = evidence
        self.toolbar = toolbar
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
        guard !stopped, phase != .failed else { return } // closed before deferred start, or renderer unavailable
        UIApplication.shared.isIdleTimerDisabled = true
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
        for (name, label) in [(UIApplication.willResignActiveNotification, "resignActive"),
                              (UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.willEnterForegroundNotification, "foreground"),
                              (UIApplication.didBecomeActiveNotification, "active"),
                              (UIApplication.didReceiveMemoryWarningNotification, "memoryWarning")] {
            #if !((DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS)
            if name == UIApplication.didReceiveMemoryWarningNotification ||
                name == UIApplication.willEnterForegroundNotification { continue }
            #endif
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Not active: the system may stop presenting, which is not a stalled video path.
                    if label == "resignActive" || label == "background" {
                        self.mailbox.setDisplayActive(false)
                        self.toolbar.setSceneActive(false)
                    }
                    if label == "active" { self.mailbox.setDisplayActive(true); self.toolbar.setSceneActive(true) }
                    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                    if self.lifecycleEvents.count < 64 {
                        self.lifecycleEvents.append("\(label)@\(DispatchTime.now().uptimeNanoseconds)")
                        self.evidence?.set("lifecycle.events", self.lifecycleEvents.joined(separator: " "))
                    }
                    #endif
                }
            })
        }
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.toolbar.assistiveTechnologyChanged() }
            })
        }
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
        renderer?.stop()
        resolveTrust(false)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let flush = evidenceFlush()
        #endif
        if let session {
            self.session = nil
            Task {
                await session.disconnect()
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                flush()
                #endif
            }
        } else {
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if let replayer { replayer.stop(then: flush) }
            else { flush() }
            #endif
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        replayer = nil
        pipeline = nil
        #endif
        UIApplication.shared.isIdleTimerDisabled = false
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
            startTask = nil
            guard let g = geometry else {
                phaseChanged(.failed, "Display setup is unavailable.")
                return
            }
            let display = DisplayRequest(viewportPixels: g.usefulPixels.size, profile: profile)
            let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: mailbox, evidence: log)
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            self.pipeline = pipeline
            #endif
            let config = SessionConfiguration(
                host: request.host, username: request.username,
                logicalWidth: display.logicalWidth, logicalHeight: display.logicalHeight, hidpiScale: Double(profile.scale),
                hardwareModel: DeviceInfo.machine, osBuild: DeviceInfo.osBuild, osVersion: DeviceInfo.osVersion)
            log.set("session.request", "\(request.host) \(display.summary)")
            let session = HPSSSession(
                config: config, password: request.password, pipeline: pipeline, evidence: log, channel: channel,
                trust: { [weak self] host, fingerprint in
                    await self?.askTrust(host: host, fingerprint: fingerprint) ?? false
                },
                onPhase: { [weak self] phase, detail in
                    Task { @MainActor in self?.phaseChanged(phase, detail) }
                })
            self.session = session
            Task { [weak self] in
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
            }
        }
    }

    private func phaseChanged(_ p: SessionPhase, _ detail: String) {
        phase = p
        if [.idle, .disconnecting, .failed].contains(p) {
            inputReady = false
            inputRecovery = nil
            inputQueue.removeAll()
            inputOverflowNotice = nil
            toolbar.sessionEnded()
        }
        if p != .streaming { mediaStalledSeconds = nil }
        if p == .streaming {
            // Successful establishment = the first presented desktop of this session.
            if !hasPresentedDesktop, !stopped { toolbar.sessionEstablished(offeringHint: wasLive) }
            hasPresentedDesktop = true
            scheduleDisplayChange()
        }
        if p == .idle, status.hasPrefix("disconnected") { return }       // keep the reason
        status = detail.isEmpty ? p.rawValue : "\(p.rawValue): \(detail)"
        print("[vicinia] session \(status)")
    }

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
