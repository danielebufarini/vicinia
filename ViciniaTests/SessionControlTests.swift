// Vicinia tests — the real HPSSSession's serialized control path against a
// loopback fake host that continues past authentication.
// SPDX-License-Identifier: MIT
//
// Covers the session's own outbox, release barrier, resize ordering and
// teardown interleavings end to end.
// Verifies that the dispatched-input ledger tracks only events actually
// dispatched on the wire, not events merely queued.

import AVFAudio
import Foundation
import Synchronization
import Testing
import UIKit
@testable import Vicinia

/// Server side of the control channel after a valid login: prelude, 1103
/// rekey, encrypted records, media-init message 1, one layout and an answer.
actor FakeControlPeer {
    enum Stall: Sendable { case none, beforeRekey, beforeMediaInit }
    static let logical = (width: 1164, height: 600), backing = (width: 2328, height: 1200)
    static let geometry = DesktopGeometry(logical: CGRect(x: 0, y: 0, width: 1164, height: 600),
                                          backing: CGRect(x: 0, y: 0, width: 2328, height: 1200))

    private let stall: Stall
    private var channel: ControlChannel?
    private var records: RecordLayer?
    /// Decrypted client writes in wire order (one sealed record per write here).
    private(set) var received: [[UInt8]] = []
    private(set) var closed = false
    private(set) var failure: String?

    init(stall: Stall = .none) { self.stall = stall }

    func serve(_ ch: ControlChannel, wrapKey: [UInt8]) async {
        channel = ch
        do { try await run(ch, wrapKey: wrapKey) } catch ChannelError.closed {
        } catch { failure = "\(error)" }
        closed = true
    }

    private func run(_ ch: ControlChannel, wrapKey: [UInt8]) async throws {
        _ = try await ch.read(1, timeout: .seconds(5), "ClientInit")
        var serverInit = ByteWriter()
        serverInit.u16(UInt16(Self.logical.width)); serverInit.u16(UInt16(Self.logical.height))
        serverInit.zeros(16); serverInit.u32(4); serverInit.append(Array("fake".utf8))
        try await ch.send(serverInit.bytes)
        _ = try await ch.read(66 + 12, timeout: .seconds(5), "ViewerInfo + 0x12")
        let display = try await ch.read(4, timeout: .seconds(5), "0x1d header")
        _ = try await ch.read(Int(display[2]) << 8 | Int(display[3]), timeout: .seconds(5), "0x1d body")
        let encodings = try await ch.read(4, timeout: .seconds(5), "SetEncodings header")
        _ = try await ch.read(4 * (Int(encodings[2]) << 8 | Int(encodings[3])), timeout: .seconds(5), "SetEncodings")
        if stall == .beforeRekey { return try await untilClosed(ch) }

        let key = try Crypto.randomBytes(16), iv = try Crypto.randomBytes(16)
        let rekey = [0, 0, 0, 1] + (try Crypto.aesECBEncryptBlock(key: wrapKey, block: key))
            + (try Crypto.aesECBEncryptBlock(key: wrapKey, block: iv))
        let layer = try RecordLayer(rekey: rekey, wrapKey: wrapKey)
        records = layer
        try await ch.send(Self.update([(1103, rekey)]))                           // plaintext, carries the rekey
        _ = try await ch.read(8, timeout: .seconds(5), "0x12 toggle")

        var announced = false
        while true {
            let lb = try await ch.read(2, timeout: .seconds(60), "record length")
            let body = try layer.open(try await ch.read(Int(lb[0]) << 8 | Int(lb[1]), timeout: .seconds(5), "record"))
            received.append(body)
            if !announced {
                announced = true
                if stall == .beforeMediaInit { continue }
                try await sendMediaInit()
            }
            if body.first == 0x1C {                                               // the offer: layout, then the answer
                try await send(Self.update([(1105, Self.sized(Self.layout()))]))
                var answer = [UInt8](repeating: 0, count: 16); answer[1] = 2      // message 2 without a canvas
                try await send(Self.update([(1010, Self.sized(answer))]))
            }
        }
    }

    private func untilClosed(_ ch: ControlChannel) async throws {
        while true { _ = try await ch.read(1, timeout: .seconds(60), "close") }
    }

    /// Sends one server message as an encrypted record.
    func send(_ message: [UInt8]) async throws {
        guard let channel, let records else { throw ChannelError.closed("peer not ready") }
        try await channel.send(try records.seal(message))
    }

    /// A well-framed record that cannot authenticate: fatal for the client.
    func sendCorruptRecord() async throws {
        guard let channel else { throw ChannelError.closed("peer not ready") }
        try await channel.send([0, 32] + [UInt8](repeating: 0xA5, count: 32))
    }

    func sendUnchangedLayout() async throws {
        try await send(Self.update([(1105, Self.sized(Self.layout()))]))
    }

    /// Media-init message 1 (same ports): the host starts a media negotiation.
    func sendMediaInit() async throws {
        var m1 = [UInt8](repeating: 0, count: 24)
        m1[1] = 1; m1.putU16(59_000, at: 8); m1.putU16(59_001, at: 14)
        try await send(Self.update([(1010, Self.sized(m1))]))
    }

    /// The host reconfigures its virtual display to another geometry.
    func sendChangedLayout() async throws {
        try await send(Self.update([(1105, Self.sized(Self.layout(logical: (1280, 720), backing: (2560, 1440))))]))
    }

    /// Pointer events (Apple wrapper decrypted): button mask per event, wire order, from `index`.
    func pointerMasks(from index: Int = 0) -> [UInt8] {
        guard let records else { return [] }
        var out: [UInt8] = []
        for body in received.dropFirst(index) where body.first == 0x10 {
            var offset = 0
            while offset + 18 <= body.count, body[offset] == 0x10 {
                if let plain = try? Crypto.aesECBDecryptBlock(key: records.wrapKey, block: Array(body[offset + 2 ..< offset + 18])) {
                    out.append(plain[11])
                }
                offset += 18
            }
        }
        return out
    }

    /// First byte of every client write from `index` (0x10 pointer, 0x1d display request, …).
    func kinds(from index: Int) -> [UInt8] { received.dropFirst(index).compactMap(\.first) }

    struct KeyEvent: Equatable, Sendable {
        let key: UInt32
        let down: Bool
    }

    /// Read key transitions even in a barrier that also releases a pointer.
    func keyEvents(from index: Int) -> [KeyEvent] {
        var result: [KeyEvent] = []
        for body in received.dropFirst(index) {
            var offset = 0
            while offset < body.count {
                if body[offset] == 4, offset + 8 <= body.count {
                    let key = body[offset + 4 ..< offset + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    result.append(KeyEvent(key: key, down: body[offset + 1] != 0))
                    offset += 8
                } else if body[offset] == 0x10, offset + 18 <= body.count {
                    offset += 18
                } else { break }
            }
        }
        return result
    }

    private static func sized(_ body: [UInt8]) -> [UInt8] { [UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body }

    private static func update(_ rects: [(Int32, [UInt8])]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(UInt16(rects.count))
        for (encoding, body) in rects { w.zeros(8); w.i32(encoding); w.append(body) }
        return w.bytes
    }

    /// 0x451 layout: one display at the origin, by default logical 1164×600, backing 2328×1200.
    private static func layout(logical: (width: Int, height: Int) = FakeControlPeer.logical,
                               backing: (width: Int, height: Int) = FakeControlPeer.backing) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20 + 56)
        b.putU16(UInt16(logical.width), at: 2); b.putU16(UInt16(logical.height), at: 4)
        b.putU16(UInt16(backing.width), at: 6); b.putU16(UInt16(backing.height), at: 8)
        b.putU16(1, at: 18)
        let entry = 20 + 20                                                        // rects: y0, x0, y1, x1
        b.putU16(UInt16(logical.height), at: entry + 4); b.putU16(UInt16(logical.width), at: entry + 6)
        b.putU16(UInt16(backing.height), at: entry + 12); b.putU16(UInt16(backing.width), at: entry + 14)
        return b
    }
}

/// Holds control sends "in flight" while closed.
final class SendGate: Sendable {
    private struct State { var open = true; var parked: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())
    var waiting: Int { state.withLock { $0.parked.count } }
    func close() { state.withLock { $0.open = false } }
    func open() {
        let parked = state.withLock { s in
            s.open = true
            let p = s.parked
            s.parked = []
            return p
        }
        for c in parked { c.resume() }
    }
    func pass() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let proceed = state.withLock { s in
                if s.open { return true }
                s.parked.append(c)
                return false
            }
            if proceed { c.resume() }
        }
    }
}

@Suite("Session control path", .serialized)
struct SessionControlTests {
    private static let pinHost = "127.0.0.1"
    private let moreSpace = DisplayRequest(viewportPixels: CGSize(width: 2328, height: 1200), profile: .moreSpace)
    private let point = CGPoint(x: 300, y: 200)

    /// Polls `condition` (5 ms) until it holds or `timeout` passes.
    private func eventually(_ timeout: Duration = .seconds(8), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private struct Rig {
        let host: FakeHost, peer: FakeControlPeer, session: HPSSSession, gate: SendGate
        let phases: Recorder<SessionPhase>, epochs: Recorder<UInt64>, mailbox: DesktopUpdateMailbox
        let evidence: EvidenceLog
        let run: Task<Void, Never>
        /// Client writes the host had received when the session reached `streaming`.
        var base = 0
        var epoch: UInt64 { epochs.all.last ?? 0 }

        func finish() async {
            gate.open()
            await session.disconnect()
            await run.value
            host.stop()
            try? HostKeyPinStore.forget(host: SessionControlTests.pinHost)
        }
    }

    @MainActor private struct ControllerRig {
        let controller: SessionController
        let view: DesktopView
        let session: HPSSSession
        let peer: FakeControlPeer
        let gate: SendGate
        let host: FakeHost
        let base: Int
        let audioSession: FakeAudioSession
    }

    /// The real controller owns authentication, epoch callbacks and presentation.
    /// A metadata-only snapshot supplies coordinates, not physical decode evidence.
    /// `presentingFirstDesktop: false` runs `body` while the first desktop is still awaited.
    /// `toolbar` defaults to an isolated one (own defaults domain, timers that never fire).
    /// Audio runs through the production pipeline with an offline output and a fake session.
    @MainActor private func withController(presentingFirstDesktop: Bool = true, toolbar: SessionToolbar? = nil,
                                           profile: ProfileBinding? = nil,
                                           decodeAccessUnit: (@Sendable (AACELDDecoder, Data) throws -> AVAudioPCMBuffer)? = nil,
                                           _ body: @MainActor (ControllerRig) async throws -> Void) async throws {
        try? HostKeyPinStore.forget(host: Self.pinHost)
        let host = try FakeHost(behavior: .valid)
        let peer = FakeControlPeer()
        host.afterAuthentication = { channel, key in await peer.serve(channel, wrapKey: key) }
        let port = try await host.start()
        let gate = SendGate()
        let channel = ControlChannel(host: Self.pinHost, port: port)
        await channel.gateSends { await gate.pass() }
        let toolbarDefaults = TestDefaults()
        let audioSession = FakeAudioSession()
        let decode = decodeAccessUnit ?? { try $0.decode($1) }
        let controller = SessionController(channel: channel, evidence: EvidenceLog(), toolbar: toolbar ?? SessionToolbar(
            defaults: toolbarDefaults.defaults, assistiveTechnologyRunning: { false }, schedule: ManualSchedule().schedule),
            makeAudio: { AudioPipeline(enabled: $0, session: audioSession, output: .offline, decodeAccessUnit: decode) },
            slot: LiveSessionSlot())  // parallel suites: not the app's single-session owner
        let view = DesktopView(frame: .zero)
        var connected: HPSSSession?

        func finish() async {
            defer { toolbarDefaults.remove() }
            gate.open()
            if let session = connected ?? controller.session {
                await session.disconnect()
                controller.stop()
                await controller.inputTask?.value
                // A concurrent stop may already own teardown: wait for its real
                // completion marker, after UDP shutdown, rather than just idle.
                #expect(await eventually(.seconds(2)) {
                    await controller.evidence?.value("session.teardown") != nil
                })
                #expect(await eventually(.seconds(2)) { await peer.closed })
            } else { controller.stop() }
            await channel.close()
            host.stop()
            try? HostKeyPinStore.forget(host: Self.pinHost)
        }

        do {
            controller.attach(view)
            try #require(controller.renderer != nil)
            view.onGeometry?(ViewportGeometry(boundsPoints: CGSize(width: 1164, height: 600),
                                              displayScale: 2, safeArea: .zero,
                                              drawablePixels: CGSize(width: 2328, height: 1200),
                                              interfaceOrientation: "landscapeRight", maximumFramesPerSecond: 60))
            controller.start(SessionSource(id: "controller-test", clipURL: nil,
                                           live: LiveRequest(host: Self.pinHost, username: "tester",
                                                             password: SecretBytes("correct horse"), profile: profile)), window: nil)
            try #require(await eventually(.seconds(2)) { await controller.trustPrompt != nil })
            #expect(controller.connectionProgress == "Authenticating with the Mac…")
            #expect(controller.terminalTitle == nil)
            controller.resolveTrust(true)
            try #require(await eventually(.seconds(2)) { await controller.phase == .awaitingRandomAccess })
            #expect(controller.connectionProgress == "Waiting for the first desktop picture…")
            #expect(controller.terminalTitle == nil)
            let session = try #require(controller.session)
            connected = session
            if presentingFirstDesktop {
                let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 2328, canvasHeight: 1200,
                                          pictureWidth: 2336, pictureHeight: 304, cropTop: 0, visibleHeight: 304)
                let mailbox = controller.mailbox
                try #require(await eventually(.seconds(2)) {
                    mailbox.reset(generation: 77, layout: layout)
                    await session.markPresented(DesktopPresentation(generation: 77, offerID: 1,
                                                                    geometry: FakeControlPeer.geometry,
                                                                    nanos: DispatchTime.now().uptimeNanoseconds))
                    return await MainActor.run { controller.inputReady && controller.phase == .streaming }
                })
                controller.renderer?.shown = DesktopSnapshot(updateSequence: 1, rtpTimestamp: 1, generation: 77,
                                                             layout: layout, stripes: [nil, nil, nil, nil],
                                                             changedStripes: [], newestSubmitNanos: 0)
                try #require(controller.renderer?.viewportTransform != nil)
            }
            let base = await peer.received.count
            try await body(ControllerRig(controller: controller, view: view, session: session,
                                         peer: peer, gate: gate, host: host, base: base, audioSession: audioSession))
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    @MainActor @Test func controllerPollsCursorWhileStreaming() async throws {
        try await withController { rig in
            let poll = RFB.framebufferUpdateRequest(incremental: true, w: 1, h: 1)
            #expect(await eventually(.seconds(2)) {
                await rig.peer.received.dropFirst(rig.base).filter { $0 == poll }.count >= 2
            })
        }
    }

    /// A display change claims a retained desktop only after one was actually presented:
    /// the host may reconfigure while the first desktop is still awaited.
    @MainActor @Test func displayChangeFeedbackClaimsARetainedDesktopOnlyAfterOneWasPresented() async throws {
        try await withController(presentingFirstDesktop: false) { rig in
            try await rig.peer.sendChangedLayout()
            try #require(await eventually(.seconds(2)) { await rig.controller.phase == .hostReconfiguring })
            #expect(rig.controller.connectionProgress == "Negotiating the remote display…")
            #expect(rig.controller.terminalTitle == nil)
        }
        try await withController { rig in
            try await rig.peer.sendChangedLayout()
            try #require(await eventually(.seconds(2)) { await rig.controller.phase == .hostReconfiguring })
            #expect(rig.controller.connectionProgress == "Updating display… Last complete desktop retained")
            #expect(rig.controller.terminalTitle == nil)
        }
        try await withController { rig in
            await rig.session.requestResize(moreSpace)
            try #require(await eventually(.seconds(2)) { await rig.controller.phase == .resizing })
            #expect(rig.controller.connectionProgress == "Updating display… Last complete desktop retained")
            #expect(rig.controller.terminalTitle == nil)
        }
    }

    @MainActor @Test func localPinchSendsNoRemoteInputOrDisplayRequestAndPreservesClickMapping() async throws {
        try await withController { rig in
            let renderer = try #require(rig.controller.renderer)
            // Initialize the cursor through ordinary input before testing takeover:
            // the first release is otherwise allowed to initialize it at center.
            rig.view.onInput?(.absolute(CGPoint(x: 582, y: 300)))
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base).count == 1 })
            let base = await rig.peer.received.count
            let focal = CGPoint(x: 1000, y: 400), moved = CGPoint(x: 1030, y: 420)
            let remote = try #require(renderer.viewportTransform?.desktopPoint(fromView: focal))
            let pinch = PinchSample()
            var events: [String] = []
            let onInput = rig.view.onInput
            rig.view.onInput = { event in
                if case .release = event { events.append("release") } else { events.append("remote") }
                onInput?(event)
            }
            let cursor = renderer.cursorPoint
            pinch.send(to: rig.view, .began, at: focal)
            pinch.send(to: rig.view, .changed, scale: 2, at: focal)
            pinch.send(to: rig.view, .changed, scale: 0.8, at: moved)
            pinch.send(to: rig.view, .ended, at: .zero)
            #expect(events == ["release"]) // existing takeover barrier only; no local pinch input
            #expect(renderer.cursorPoint == cursor)
            // A later real key is a dispatch marker: inspect every preceding wire event.
            rig.view.insertText("z")
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: base).last == .init(key: 122, down: false)
            })
            #expect(await rig.peer.pointerMasks(from: base).isEmpty)
            let kinds = await rig.peer.kinds(from: base)
            #expect(!kinds.contains(0x1d) && !kinds.contains(0x1c)) // no display request or media offer
            #expect(rig.controller.mailbox.isCurrent(generation: 77))
            rig.view.onInput?(.click(moved, 1, false))
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: base).count == 2 })
            #expect(await rig.peer.pointerMasks(from: base) == [1, 0])
            let cursorAfterClick = try #require(renderer.cursorPoint)
            #expect(abs(cursorAfterClick.x - remote.x) < 0.00001 && abs(cursorAfterClick.y - remote.y) < 0.00001)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Boundary stress cases starting at 129 synchronous Escape pairs,
    /// followed by ordinary text through the actual view/controller/session path.
    @MainActor @Test func controllerSynchronousBurstsContinue() async throws {
        for pairs in [129, 128, 256, 257] {
            try await withController { rig in
                for _ in 0..<pairs { rig.controller.escape() } // one main-actor turn; no drain can interleave
                await rig.controller.inputTask?.value
                #expect(rig.controller.session === rig.session)
                #expect(rig.controller.phase == .streaming)
                #expect(await rig.session.phase == .streaming)
                #expect(rig.controller.evidence?.value("session.teardown") == nil)
                rig.view.insertText("z")
                await rig.controller.inputTask?.value
                #expect(await eventually(.seconds(1)) {
                    await rig.peer.keyEvents(from: rig.base).contains(.init(key: 122, down: false))
                }, "ordinary input must reach the peer after \(pairs) synchronous pairs")
                let keys = await rig.peer.keyEvents(from: rig.base)
                #expect(keys.filter { $0.key == 0xff1b }.count == (pairs <= 256 ? pairs * 2 : 0))
                #expect(keys.suffix(2) == [.init(key: 122, down: true), .init(key: 122, down: false)])
                #expect(rig.host.proofs.all == [true])
            }
        }
    }

    // MARK: Immersive session controls

    @MainActor private func isolatedToolbar(_ timers: ManualSchedule, _ store: TestDefaults) -> SessionToolbar {
        SessionToolbar(defaults: store.defaults, assistiveTechnologyRunning: { false }, schedule: timers.schedule)
    }

    /// Establishment is the first presented desktop; teardown leaves nothing scheduled.
    @MainActor @Test func toolbarAndHintStartOnlyWithTheFirstPresentedDesktop() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let waiting = isolatedToolbar(timers, store)
        try await withController(presentingFirstDesktop: false, toolbar: waiting) { rig in
            #expect(rig.controller.phase == .awaitingRandomAccess)
            #expect(waiting.stage == .pending && waiting.isVisible && !waiting.showsHint && timers.entries.isEmpty)
            rig.view.onToolbarToggle?()
            #expect(waiting.isVisible) // Close stays reachable until the desktop is shown
        }
        #expect(waiting.stage == .ended && timers.entries.isEmpty)
        #expect(!store.defaults.bool(forKey: SessionToolbar.hintShownKey))

        let connected = isolatedToolbar(timers, store)
        try await withController(toolbar: connected) { _ in
            #expect(connected.stage == .established && connected.isVisible && connected.showsHint)
            #expect(store.defaults.bool(forKey: SessionToolbar.hintShownKey))
            #expect(timers.live.count == 2) // dismissal and hint
        }
        #expect(connected.stage == .ended && timers.live.isEmpty)
    }

    /// Gesture and accessibility toggles are local: only the marker reaches the Mac.
    @MainActor @Test func toolbarTogglesSendNoRemoteInput() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            let tap = TapSample()
            tap.send(to: rig.view, "toolbarToggled:")
            #expect(!toolbar.isVisible)
            tap.send(to: rig.view, "toolbarToggled:")
            #expect(toolbar.isVisible)
            #expect(rig.view.accessibilityPerformMagicTap() && !toolbar.isVisible)
            #expect(rig.view.accessibilityActivate() && toolbar.isVisible)
            rig.view.insertText("z") // dispatch marker after every toggle
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).last == .init(key: 122, down: false)
            })
            #expect(await rig.peer.keyEvents(from: rig.base) == [.init(key: 122, down: true), .init(key: 122, down: false)])
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Deliberate product decision: no local keyboard shortcut. Command-Shift-T is
    /// ordinary typing: delivered exactly, and like any typing it dismisses a
    /// visible toolbar; it never shows a hidden one.
    @MainActor @Test func commandShiftTReachesTheMacAsOrdinaryTyping() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            @MainActor func chord() {
                rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
                rig.view.keyDown(.keyboardLeftShift, symbol: 0xffe1)
                rig.view.keyDown(.keyboardT, symbol: 0x74)
                rig.view.keyUp(.keyboardT); rig.view.keyUp(.keyboardLeftShift); rig.view.keyUp(.keyboardLeftGUI)
            }
            #expect(toolbar.isVisible)
            chord()
            #expect(!toolbar.isVisible)
            chord()
            #expect(!toolbar.isVisible)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.keyEvents(from: rig.base).count == 12 })
            let once: [FakeControlPeer.KeyEvent] = [
                .init(key: 0xffeb, down: true), .init(key: 0xffe1, down: true), .init(key: 0x74, down: true),
                .init(key: 0x74, down: false), .init(key: 0xffe1, down: false), .init(key: 0xffeb, down: false),
            ]
            #expect(await rig.peer.keyEvents(from: rig.base) == once + once)
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
        }
    }

    /// Pointer ownership: the pointer is local while the toolbar is visible and locked
    /// again only after the remote button is released. Every real lock change
    /// runs the existing release barrier (`focusLost` → `cancelInput`),
    /// performed here explicitly where the system would change the lock.
    @MainActor @Test func pointerHandOverKeepsRemoteButtonsBalanced() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            let p = CGPoint(x: 582, y: 300), q = CGPoint(x: 620, y: 330)
            #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
            rig.view.onInput?(.button(p, 1, false))  // local pointer: a desktop press dismisses the toolbar…
            #expect(!toolbar.isVisible && !toolbar.prefersPointerLock) // …and the drag keeps the pointer
            rig.view.onInput?(.button(q, 1, false))
            rig.view.onInput?(.button(q, 0, false))
            #expect(toolbar.prefersPointerLock)
            rig.view.cancelInput()                   // lock acquired
            rig.view.onInput?(.relative(CGPoint(x: 5, y: 5)))
            rig.view.onInput?(.button(.zero, 1, true)) // locked press: the lock stays
            #expect(toolbar.prefersPointerLock)
            rig.view.onToolbarToggle?()              // toolbar shown while that button is held
            #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
            rig.view.cancelInput()                   // lock released: the held button is released
            rig.view.onInput?(.click(p, 1, false))   // local-pointer click on the desktop
            #expect(!toolbar.isVisible && toolbar.prefersPointerLock)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base).count == 8 })
            let masks = await rig.peer.pointerMasks(from: rig.base)
            #expect(masks == [1, 1, 0, 0, 1, 0, 1, 0]) // drag, move, locked press released, click
            #expect(await rig.peer.keyEvents(from: rig.base).isEmpty)
        }
    }

    /// Holding Command while the toolbar auto-hides must not release
    /// Command remotely when pointer lock is acquired; the later key-up is the
    /// only release. The handover barrier sends nothing (no button is held).
    @MainActor @Test func commandHeldAcrossAutomaticDismissalAndLockAcquisition() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
            rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
            #expect(toolbar.isVisible) // a modifier down dismisses nothing
            timers.fire(try #require(timers.live.first { $0.delay == SessionToolbar.autoHideDelay }))
            #expect(!toolbar.isVisible && toolbar.prefersPointerLock)
            rig.view.cancelPointer() // lock acquired
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffeb, down: true)]
            })
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty) // the handover sent nothing
            rig.view.keyUp(.keyboardLeftGUI)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).count == 2
            })
            #expect(await rig.peer.keyEvents(from: rig.base)
                == [.init(key: 0xffeb, down: true), .init(key: 0xffeb, down: false)])
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// An ordinary key held across toolbar-driven lock transitions in
    /// both directions. The key-down itself dismisses the toolbar (intentional
    /// action); neither the acquisition nor the later release handover may
    /// release the still-held key.
    @MainActor @Test func ordinaryKeyHeldAcrossToolbarDrivenLockTransitions() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            rig.view.keyDown(.keyboardA, symbol: 0x61)
            #expect(!toolbar.isVisible && toolbar.prefersPointerLock) // typing dismisses, lock requested
            rig.view.cancelPointer() // lock acquired
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true)]
            })
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            rig.view.onToolbarToggle?() // toolbar shown again
            #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
            rig.view.cancelPointer() // lock released
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true)]
            })
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            rig.view.keyUp(.keyboardA)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).count == 2
            })
            #expect(await rig.peer.keyEvents(from: rig.base)
                == [.init(key: 0x61, down: true), .init(key: 0x61, down: false)])
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// After a lock transition with Command held, a Command-click is
    /// delivered while Command is still down remotely (modifier-assisted), and
    /// the later key-up is the only release.
    @MainActor @Test func modifierAssistedClickAfterLockTransition() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            let p = CGPoint(x: 582, y: 300)
            rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
            timers.fire(try #require(timers.live.first { $0.delay == SessionToolbar.autoHideDelay }))
            #expect(!toolbar.isVisible && toolbar.prefersPointerLock)
            rig.view.cancelPointer() // lock acquired
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffeb, down: true)]
            })
            rig.view.onInput?(.click(p, 1, false)) // Command-click on the desktop
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base) == [1, 0] })
            #expect(await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffeb, down: true)])
            rig.view.keyUp(.keyboardLeftGUI)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).count == 2
            })
            #expect(await rig.peer.pointerMasks(from: rig.base) == [1, 0])
            #expect(await rig.peer.keyEvents(from: rig.base)
                == [.init(key: 0xffeb, down: true), .init(key: 0xffeb, down: false)])
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Rapid toolbar toggles with Command held. Every handover leaves
    /// the key alone; the later key-up is the only release.
    @MainActor @Test func rapidToolbarTogglesPreserveHeldKeys() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
            for _ in 0..<10 {
                rig.view.onToolbarToggle?()
                rig.view.cancelPointer() // each transition hands the pointer over
            }
            #expect(toolbar.isVisible) // an even count returns to shown
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffeb, down: true)]
            })
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            rig.view.keyUp(.keyboardLeftGUI)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).count == 2
            })
            #expect(await rig.peer.keyEvents(from: rig.base)
                == [.init(key: 0xffeb, down: true), .init(key: 0xffeb, down: false)])
            #expect(await rig.peer.pointerMasks(from: rig.base).isEmpty)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Genuine focus loss still releases all remote input at once
    /// (buttons first, then keys in reverse), forgets held keys locally so
    /// their later key-ups send nothing, and leaves input balanced.
    @MainActor @Test func actualFocusLossStillReleasesAllRemoteInput() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            let p = CGPoint(x: 582, y: 300)
            rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
            rig.view.keyDown(.keyboardA, symbol: 0x61)
            rig.view.onInput?(.button(p, 1, false))
            rig.view.cancelInput() // genuine focus loss
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base) == [1, 0] })
            #expect(await rig.peer.keyEvents(from: rig.base) == [
                .init(key: 0xffeb, down: true), .init(key: 0x61, down: true),
                .init(key: 0x61, down: false), .init(key: 0xffeb, down: false),
            ])
            rig.view.keyUp(.keyboardA); rig.view.keyUp(.keyboardLeftGUI) // forgotten locally: nothing more
            await rig.controller.inputTask?.value
            #expect(await rig.peer.keyEvents(from: rig.base).count == 4)
            #expect(await rig.peer.pointerMasks(from: rig.base) == [1, 0])
            rig.view.onInput?(.click(p, 1, false)) // balanced afterwards
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.pointerMasks(from: rig.base) == [1, 0, 1, 0]
            })
            #expect(await rig.peer.keyEvents(from: rig.base).count == 4)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// A lock release with both a button and Command held releases
    /// the button (balanced handover) but preserves Command; the later key-up
    /// is the only key release.
    @MainActor @Test func pointerHandoverReleasesButtonsButPreservesKeys() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            rig.view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
            rig.view.onInput?(.button(.zero, 1, true)) // a press dismisses the toolbar…
            #expect(!toolbar.isVisible && !toolbar.prefersPointerLock) // …and the drag keeps the pointer
            rig.view.onToolbarToggle?() // toolbar shown while that button is held
            #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
            rig.view.cancelPointer() // lock released: the held button is released, Command survives
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base) == [1, 0] })
            #expect(await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffeb, down: true)])
            rig.view.keyUp(.keyboardLeftGUI)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: rig.base).count == 2
            })
            #expect(await rig.peer.pointerMasks(from: rig.base) == [1, 0])
            #expect(await rig.peer.keyEvents(from: rig.base)
                == [.init(key: 0xffeb, down: true), .init(key: 0xffeb, down: false)])
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Clicks dismiss the toolbar and are still delivered, balanced; motion and
    /// modifiers do not dismiss it.
    @MainActor @Test func intentionalRemoteInputDismissesTheToolbarAndIsDelivered() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            rig.view.onInput?(.absolute(CGPoint(x: 582, y: 300)))
            #expect(toolbar.isVisible)
            rig.view.onInput?(.click(CGPoint(x: 582, y: 300), 1, false))
            #expect(!toolbar.isVisible)
            rig.view.onToolbarToggle?()
            rig.view.onInput?(.key(0xffe3, true)); rig.view.onInput?(.key(0xffe3, false))
            #expect(toolbar.isVisible)
            rig.view.onInput?(.click(CGPoint(x: 600, y: 310), 4, false))
            #expect(!toolbar.isVisible)
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) { await rig.peer.pointerMasks(from: rig.base).count == 5 })
            let masks = await rig.peer.pointerMasks(from: rig.base)
            #expect(masks == [0, 1, 0, 2, 0]) // move, left click, right click (Apple wire mask: right = 2)
            #expect(await rig.peer.keyEvents(from: rig.base) == [.init(key: 0xffe3, down: true), .init(key: 0xffe3, down: false)])
        }
    }

    /// Showing, hiding and automatically dismissing the toolbar changes no
    /// renderer, layer, viewport, zoom, mapping, display request or session.
    @MainActor @Test func toolbarVisibilityLeavesRenderingAndSessionUntouched() async throws {
        let store = TestDefaults(), timers = ManualSchedule()
        defer { store.remove() }
        let toolbar = isolatedToolbar(timers, store)
        try await withController(toolbar: toolbar) { rig in
            let renderer = try #require(rig.controller.renderer)
            let layer = rig.view.metalLayer
            let focal = CGPoint(x: 900, y: 350), pinch = PinchSample()
            pinch.send(to: rig.view, .began, at: focal)
            pinch.send(to: rig.view, .changed, scale: 1.6, at: focal)
            pinch.send(to: rig.view, .ended, at: .zero)
            let transform = try #require(renderer.viewportTransform)
            let mapped = try #require(transform.desktopPoint(fromView: focal))
            let zoom = renderer.zoom, pan = renderer.pan, pixels = renderer.viewportPixels
            let scale = renderer.displayScale, drawable = layer.drawableSize, profile = rig.controller.profile
            let base = await rig.peer.received.count
            for _ in 0..<6 { rig.view.onToolbarToggle?() }
            toolbar.controlUsed(); toolbar.setMenuOpen(true); toolbar.setMenuOpen(false)
            for entry in timers.live { timers.fire(entry) } // automatic dismissal
            #expect(!toolbar.isVisible)
            #expect(rig.controller.renderer === renderer && rig.view.metalLayer === layer && layer.drawableSize == drawable)
            #expect(renderer.viewportTransform == transform && renderer.zoom == zoom && renderer.pan == pan)
            #expect(renderer.viewportPixels == pixels && renderer.displayScale == scale)
            #expect(renderer.viewportTransform?.desktopPoint(fromView: focal) == mapped)
            #expect(rig.controller.profile == profile && rig.controller.mailbox.isCurrent(generation: 77))
            rig.view.insertText("z")
            await rig.controller.inputTask?.value
            try #require(await eventually(.seconds(1)) {
                await rig.peer.keyEvents(from: base).last == .init(key: 122, down: false)
            })
            let kinds = await rig.peer.kinds(from: base)
            #expect(!kinds.contains(0x1d) && !kinds.contains(0x1c)) // no display request or media offer
            #expect(await rig.peer.pointerMasks(from: base).isEmpty)
            #expect(rig.controller.session === rig.session && rig.controller.phase == .streaming)
        }
    }

    /// Connects the real session to the fake host; with `streaming` it is taken
    /// through negotiation and a presented desktop, i.e. input is enabled.
    private func connect(stall: FakeControlPeer.Stall = .none, streaming: Bool = true) async throws -> Rig {
        try? HostKeyPinStore.forget(host: Self.pinHost)
        let host = try FakeHost(behavior: .valid)
        let peer = FakeControlPeer(stall: stall)
        host.afterAuthentication = { channel, key in await peer.serve(channel, wrapKey: key) }
        let port = try await host.start()
        let gate = SendGate()
        let channel = ControlChannel(host: "127.0.0.1", port: port)
        await channel.gateSends { await gate.pass() }
        let phases = Recorder<SessionPhase>(), epochs = Recorder<UInt64>()
        let mailbox = DesktopUpdateMailbox()
        let evidence = EvidenceLog()
        let config = SessionConfiguration(host: Self.pinHost, port: port, username: "tester",
                                          logicalWidth: FakeControlPeer.logical.width,
                                          logicalHeight: FakeControlPeer.logical.height,
                                          hardwareModel: "test", osBuild: "test", osVersion: (27, 2, 1))
        let session = HPSSSession(
            config: config, password: SecretBytes("correct horse"),
            pipeline: MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil, mailbox: mailbox, evidence: evidence),
            evidence: evidence, channel: channel,
            trust: { _, _ in true }, onPhase: { phase, _ in phases.add(phase) })
        await session.bindInput(epoch: { epoch, ready in if ready { epochs.add(epoch) } }, cursor: { _, _ in })
        let run = Task { await session.run() }
        var rig = Rig(host: host, peer: peer, session: session, gate: gate, phases: phases, epochs: epochs,
                      mailbox: mailbox, evidence: evidence, run: run)
        guard streaming else { return rig }
        #expect(await eventually { phases.all.contains(.awaitingRandomAccess) || phases.all.contains(.failed) })
        try #require(!phases.all.contains(.failed), "negotiation failed: \(phases.all)")
        // Stand in for the renderer: a complete desktop of the current offer was presented.
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 2328, canvasHeight: 1200,
                                  pictureWidth: 2336, pictureHeight: 304, cropTop: 0, visibleHeight: 304)
        #expect(await eventually {
            mailbox.reset(generation: 77, layout: layout)
            await session.markPresented(DesktopPresentation(generation: 77, offerID: 1, geometry: FakeControlPeer.geometry,
                                                            nanos: DispatchTime.now().uptimeNanoseconds))
            return phases.all.contains(.streaming)
        })
        // Offer, its update request and the layout rearm have all reached the host; nothing else is pending.
        #expect(await eventually {
            let kinds = await peer.kinds(from: 0)
            return kinds.contains(0x09) && kinds.contains(0x1C)
        })
        rig.base = await peer.received.count
        return rig
    }

    /// A press whose send is still in flight when a resize starts: the release
    /// record is sent after it and before the display request.
    @Test func resizeReleasesAnInFlightPressBeforeTheDisplayRequest() async throws {
        let rig = try await connect()
        let session = rig.session, peer = rig.peer, gate = rig.gate, base = rig.base, epoch = rig.epoch, point = point
        gate.close()
        let press = Task { await session.dispatchInput(.buttons(point, 1), epoch: epoch) }
        #expect(await eventually { gate.waiting == 1 })                          // sealed, not yet on the wire
        let resize = Task { [moreSpace] in await session.requestResize(moreSpace) }
        #expect(await eventually { await session.pendingWrites == 1 })           // the release barrier waits behind it
        gate.open()
        #expect(await eventually { await peer.kinds(from: base).contains(0x1D) })
        let kinds = await peer.kinds(from: base), masks = await peer.pointerMasks(from: base)
        #expect(kinds == [0x10, 0x10, 0x1D])
        #expect(masks == [1, 0])
        await press.value; await resize.value
        #expect(rig.phases.all.contains(.resizing))
        await rig.finish()
    }

    /// A resize runs to its first coherent presentation in every build; its
    /// request is timed only where measurement is compiled in. The in-flight
    /// slot is released, so a later request is still sent.
    @Test func completedResizeIsTimedOnlyInInstrumentedBuilds() async throws {
        let rig = try await connect()
        let session = rig.session, peer = rig.peer, base = rig.base, mailbox = rig.mailbox, evidence = rig.evidence
        await session.requestResize(moreSpace)
        #expect(await eventually { await peer.kinds(from: base).contains(0x1D) })
        #expect(await session.phase == .resizing)
        try await peer.sendMediaInit()                                           // the host renegotiates media
        #expect(await eventually { await session.phase == .awaitingRandomAccess })
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 2328, canvasHeight: 1200,
                                  pictureWidth: 2336, pictureHeight: 304, cropTop: 0, visibleHeight: 304)
        #expect(await eventually {
            mailbox.reset(generation: 78, layout: layout)
            await session.markPresented(DesktopPresentation(generation: 78, offerID: 2, geometry: FakeControlPeer.geometry,
                                                            nanos: DispatchTime.now().uptimeNanoseconds))
            return await session.phase == .streaming
        })
        let request = try #require(evidence.value("resize.request.1"))
        let sent = request.split(separator: " ").last.flatMap { UInt64($0) }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        #expect(sent.map { $0 > 0 } == true)
        #expect(evidence.value("resize.result.1")?.contains("first coherent presentation") == true)
        #expect(evidence.value("resize.timesMs") != nil)
        #else
        #expect(sent == 0)
        #expect(evidence.value("resize.result.1") == nil)
        #expect(evidence.value("resize.timesMs") == nil)
        #endif
        await session.requestResize(DisplayRequest(viewportPixels: CGSize(width: 2328, height: 1200), profile: .retina))
        #expect(await eventually { await peer.kinds(from: base).filter { $0 == 0x1D }.count == 2 })
        #expect(evidence.value("resize.request.2") != nil)
        await rig.finish()
    }

    /// Covers actual insertText overflow, partial occupancy, dispatched versus
    /// queued presses, subsequent right-tap mask isolation, empty release and the notice lifecycle.
    @MainActor @Test func controllerOverflowReleasesPressesAndNotifies() async throws {
        // Deterministic source-level insertion, not physical UIKit delivery.
        for count in [128, 129, 256, 257] {
            try await withController { rig in
                rig.view.insertText(String(repeating: "x", count: count))
                #expect(rig.controller.inputReady == (count <= 256))
                #expect(rig.controller.inputOverflowNotice == (count <= 256 ? nil : .recovering))
                await rig.controller.inputTask?.value
                #expect(rig.controller.inputReady)
                #expect(rig.controller.session === rig.session)
                #expect(rig.controller.phase == .streaming)
                #expect(rig.controller.mailbox.isCurrent(generation: 77))
                #expect(rig.controller.evidence?.value("session.teardown") == nil)
                rig.view.insertText("z\n")
                await rig.controller.inputTask?.value
                try #require(await eventually(.seconds(1)) {
                    await rig.peer.keyEvents(from: rig.base).last == .init(key: 0xff0d, down: false)
                })
                let keys = await rig.peer.keyEvents(from: rig.base)
                let expected: [FakeControlPeer.KeyEvent] = (0..<(count <= 256 ? count : 0)).flatMap { _ in
                    [.init(key: 120, down: true), .init(key: 120, down: false)]
                } + [.init(key: 122, down: true), .init(key: 122, down: false),
                     .init(key: 0xff0d, down: true), .init(key: 0xff0d, down: false)]
                #expect(keys == expected)
                #expect(rig.controller.inputOverflowNotice == nil)
                #expect(rig.host.proofs.all == [true])
            }
        }
        for held in ["dispatched", "queued", "empty"] {
            try await withController { rig in
                let controller = rig.controller, view = rig.view, peer = rig.peer
                let epoch = controller.inputEpoch

                // Ordinary input still keeps key pairs and coalesces adjacent moves only.
                view.onInput?(.relative(CGPoint(x: 1, y: 0)))
                view.onInput?(.relative(CGPoint(x: 2, y: 0)))
                view.insertText("d")
                view.onInput?(.relative(CGPoint(x: 3, y: 0)))
                view.onInput?(.relative(CGPoint(x: 4, y: 0)))
                await controller.inputTask?.value
                try #require(await eventually(.seconds(1)) { await peer.pointerMasks(from: rig.base).count == 2 })
                #expect(await peer.kinds(from: rig.base).filter { [UInt8(4), 0x10].contains($0) } == [0x10, 4, 4, 0x10])
                let base = await peer.received.count

                if held == "dispatched" { view.onInput?(.button(.zero, 1, true)) }
                if held != "queued" {
                    view.onInput?(.key(97, true))
                    await controller.inputTask?.value
                    try #require(await eventually(.seconds(1)) {
                        await peer.keyEvents(from: base).contains(.init(key: 97, down: true))
                    })
                }
                rig.gate.close()
                if held == "empty" { view.onInput?(.key(97, false)) }
                else { view.onInput?(.relative(CGPoint(x: 1, y: 0))) }
                try #require(await eventually(.seconds(1)) { rig.gate.waiting == 1 })
                if held == "queued" {
                    view.onInput?(.button(.zero, 1, true))
                    view.onInput?(.key(97, true))
                }
                // The two queued presses lower the boundary to 256 scalars.
                view.insertText(String(repeating: "x", count: held == "queued" ? 256 : 257))
                view.insertText("tail") // the rest of the synchronous producer remains rejected
                controller.escape()
                #expect(!controller.inputReady)
                #expect(controller.inputOverflowNotice == .recovering)
                #expect(controller.inputOverflowNotice?.message.contains("discarded") == true)
                #expect(controller.session === rig.session)
                #expect(controller.phase == .streaming)
                #expect(controller.mailbox.isCurrent(generation: 77))
                #expect(controller.evidence?.value("session.teardown") == nil)
                #expect(await rig.session.pendingWrites == 0) // recovery must wait for the popped dispatch
                rig.gate.open()
                await controller.inputTask?.value
                #expect(controller.inputReady)
                #expect(controller.inputEpoch == epoch)
                #expect(controller.inputOverflowNotice == .recovered)
                view.onInput?(.click(.zero, 4, true)) // right tap must not restore a stale left mask
                view.insertText("z")
                await controller.inputTask?.value
                #expect(controller.inputOverflowNotice == nil)
                try #require(await eventually(.seconds(1)) {
                    await peer.keyEvents(from: base).contains(.init(key: 122, down: false))
                })
                let masks = await peer.pointerMasks(from: base), keys = await peer.keyEvents(from: base)
                #expect(masks.suffix(2) == [2, 0]) // Apple's right-button bit is 2
                #expect(keys.filter { $0.key == 97 } == (held == "queued" ? [] : [.init(key: 97, down: true), .init(key: 97, down: false)]))
                #expect(!keys.contains { [UInt32(120), 116, 105, 108, 0xff1b].contains($0.key) })
                if held == "dispatched" { #expect(masks == [1, 1, 0, 2, 0]) }
                if held == "queued" { #expect(masks == [0, 2, 0]) }
                if held == "empty" { #expect(masks == [2, 0]) }
                #expect(await peer.failure == nil) // empty barriers preserved CBC sequence

                // A subsequent overflow is a new owned operation, not a stuck gate.
                for _ in 0..<257 { controller.escape() }
                #expect(controller.inputOverflowNotice == .recovering)
                await controller.inputTask?.value
                #expect(controller.inputReady && controller.inputOverflowNotice == .recovered)
                view.cancelInput()
                await controller.inputTask?.value
                #expect(controller.inputOverflowNotice == .recovered)
                view.insertText("r")
                await controller.inputTask?.value
                #expect(await eventually(.seconds(1)) {
                    await peer.keyEvents(from: base).contains(.init(key: 114, down: false))
                })
                #expect(controller.inputOverflowNotice == nil)
                #expect(controller.phase == .streaming && controller.mailbox.isCurrent(generation: 77))
                #expect(rig.host.proofs.all == [true])
            }
        }
    }

    /// Real epoch transitions and terminal paths while the recovery's own release
    /// is parked. No negative wait approaches the fake host's media-loss watchdog.
    @MainActor @Test func controllerRecoveryCannotReviveObsoleteInput() async throws {
        for action in ["layout", "resize", "stop", "stopFull", "disconnect", "integrity"] {
            try await withController { rig in
                let controller = rig.controller, session = rig.session, peer = rig.peer
                let epoch = controller.inputEpoch
                rig.view.onInput?(.button(.zero, 1, true))
                rig.view.onInput?(.key(97, true))
                await controller.inputTask?.value
                try #require(await eventually(.seconds(1)) {
                    await peer.keyEvents(from: rig.base).contains(.init(key: 97, down: true))
                })
                rig.gate.close()
                for _ in 0..<(action == "stopFull" ? 256 : 257) { controller.escape() }
                let drain = controller.inputTask
                if action == "stopFull" {
                    #expect(controller.inputReady)
                    controller.stop() // cancelInput re-enters with a full queue
                } else {
                    #expect(!controller.inputReady && controller.inputOverflowNotice == .recovering)
                }
                try #require(await eventually(.seconds(1)) { rig.gate.waiting == 1 })
                var transition: Task<Void, Never>?
                switch action {
                case "layout":
                    try await peer.sendUnchangedLayout()
                    #expect(await eventually(.seconds(1)) { await controller.inputEpoch > epoch })
                case "resize":
                    transition = Task { [moreSpace] in await session.requestResize(moreSpace) }
                    #expect(await eventually(.seconds(1)) { await controller.inputEpoch > epoch })
                case "stop": controller.stop()
                case "disconnect": transition = Task { await session.disconnect() }
                case "integrity":
                    try await peer.sendCorruptRecord()
                    #expect(await eventually(.seconds(1)) { await controller.phase == .failed })
                default: break
                }
                #expect(!controller.inputReady)
                if action != "integrity", action != "stopFull" {
                    #expect(await eventually(.seconds(1)) { await session.pendingWrites >= 1 })
                }
                rig.gate.open()
                await drain?.value
                await transition?.value
                if action == "layout" {
                    try #require(await eventually(.seconds(1)) { await controller.inputReady })
                    #expect(controller.inputEpoch > epoch)
                    #expect(controller.inputOverflowNotice == .recovered)
                    // Stale session-actor input and recovery are ineligible too.
                    await session.dispatchInput(.key(115, true), epoch: epoch)
                    #expect(await session.releaseInputForOverflow(epoch: epoch) == false)
                    rig.view.insertText("n")
                    await controller.inputTask?.value
                    try #require(await eventually(.seconds(1)) {
                        await peer.keyEvents(from: rig.base).contains(.init(key: 110, down: false))
                    })
                    #expect(await peer.keyEvents(from: rig.base).contains { $0.key == 115 || $0.key == 0xff1b } == false)
                    #expect(controller.inputOverflowNotice == nil)
                    #expect(controller.phase == .streaming)
                } else {
                    #expect(!controller.inputReady)
                    rig.view.insertText("n")
                    controller.escape()
                    await controller.inputTask?.value
                    if action == "resize" {
                        #expect(await session.phase == .resizing)
                        #expect(await eventually(.seconds(1)) { await peer.kinds(from: rig.base).contains(0x1D) })
                    } else {
                        #expect(await eventually(.seconds(1)) { await peer.closed })
                        #expect(controller.inputOverflowNotice == nil)
                    }
                    let keys = await peer.keyEvents(from: rig.base)
                    #expect(!keys.contains { $0.key == 110 || $0.key == 0xff1b })
                    if action == "integrity" {
                        #expect(await peer.pointerMasks(from: rig.base) == [1])
                        #expect(keys == [.init(key: 97, down: true)]) // no unsafe release after failed control
                    } else {
                        #expect(await peer.pointerMasks(from: rig.base) == [1, 0])
                        #expect(keys == [.init(key: 97, down: true), .init(key: 97, down: false)])
                    }
                }
            }
        }
    }

    /// At session level: a button is down on the wire; its "up" is still
    /// queued when a resize invalidates the epoch. The obsolete "up" is dropped
    /// and the mandatory barrier must release the dispatched press.
    @Test func obsoleteQueuedUpStillReleasesTheDispatchedPress() async throws {
        let rig = try await connect()
        let session = rig.session, peer = rig.peer, gate = rig.gate, base = rig.base, epoch = rig.epoch, point = point
        await session.dispatchInput(.buttons(point, 1), epoch: epoch)            // down: sent
        #expect(await eventually { await peer.pointerMasks(from: base) == [1] })
        gate.close()
        let move = Task { await session.dispatchInput(.move(CGPoint(x: 310, y: 200)), epoch: epoch) }
        #expect(await eventually { gate.waiting == 1 })                          // a drag move in flight
        let up = Task { await session.dispatchInput(.buttons(point, 0), epoch: epoch) }
        #expect(await eventually { await session.pendingWrites == 1 })           // the up is queued behind it
        let resize = Task { [moreSpace] in await session.requestResize(moreSpace) }
        #expect(await eventually { await session.pendingWrites == 2 })           // epoch closed; barrier queued
        gate.open()
        #expect(await eventually { await peer.kinds(from: base).contains(0x1D) })
        // down, in-flight move (button still held), the barrier's release — the queued up produced no record.
        let kinds = await peer.kinds(from: base), masks = await peer.pointerMasks(from: base)
        #expect(masks == [1, 1, 0])
        #expect(kinds == [0x10, 0x10, 0x10, 0x1D])
        await move.value; await up.value; await resize.value
        await rig.finish()
        let failure = await peer.failure
        #expect(failure == nil)                                                  // every record opened in sequence
    }

    /// Nothing is pressed: the barrier sends no record and does not advance the
    /// record sequence (the host opens the next record with the expected number).
    @Test func emptyBarrierSendsNothingAndKeepsTheSequence() async throws {
        let rig = try await connect()
        let base = rig.base, peer = rig.peer
        await rig.session.requestResize(moreSpace)
        #expect(await eventually { await peer.kinds(from: base).contains(0x1D) })
        let afterResize = await peer.kinds(from: base)
        #expect(afterResize == [0x1D])
        await rig.finish()                                                       // normal teardown: another empty barrier
        #expect(await eventually { await peer.closed })
        let atClose = await peer.kinds(from: base), failure = await peer.failure
        #expect(atClose == [0x1D])
        #expect(failure == nil)
    }

    /// The control channel fails while normal teardown is waiting for its
    /// release barrier: no release record may follow the failure.
    @Test func failureDuringTeardownSendsNoRelease() async throws {
        let rig = try await connect()
        let session = rig.session, peer = rig.peer, gate = rig.gate, base = rig.base, epoch = rig.epoch, point = point
        await session.dispatchInput(.buttons(point, 1), epoch: epoch)            // a press the host knows about
        #expect(await eventually { await peer.pointerMasks(from: base) == [1] })
        gate.close()
        let move = Task { await session.dispatchInput(.move(CGPoint(x: 310, y: 200)), epoch: epoch) }
        #expect(await eventually { gate.waiting == 1 })
        let disconnect = Task { await session.disconnect() }
        #expect(await eventually { await session.pendingWrites == 1 })           // teardown waits for its barrier
        try await peer.sendCorruptRecord()                                       // integrity failure on the client
        #expect(await eventually { rig.phases.all.contains(.failed) })
        gate.open()
        await move.value; await disconnect.value; await rig.run.value
        #expect(await eventually { await peer.closed })
        let masks = await peer.pointerMasks(from: base), pending = await session.pendingWrites
        #expect(masks == [1])                                                    // no move, no release after the failure
        #expect(pending == 0)
        rig.host.stop()
        try? HostKeyPinStore.forget(host: Self.pinHost)
    }

    /// Disconnecting while negotiation waits for the host ends promptly and
    /// cleanly: no failure state, the connection is closed, `run` returns.
    @Test(arguments: [FakeControlPeer.Stall.beforeRekey, .beforeMediaInit])
    func disconnectDuringNegotiationEndsCleanly(_ stall: FakeControlPeer.Stall) async throws {
        let rig = try await connect(stall: stall, streaming: false)
        let waitingIn: SessionPhase = stall == .beforeRekey ? .virtualDisplayReady : .awaitingMediaInit
        #expect(await eventually { rig.phases.all.contains(waitingIn) })
        let started = ContinuousClock.now
        await rig.session.disconnect()
        await rig.run.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(rig.phases.all.last == .idle && !rig.phases.all.contains(.failed))
        #expect(!rig.phases.all.contains(.mediaNegotiating))
        #expect(await eventually { await rig.peer.closed })
        rig.host.stop()
        try? HostKeyPinStore.forget(host: Self.pinHost)
    }

    // MARK: Mac audio and the session lifetime

    private static let audioPacket = AudioPacket(sequence: 1, timestamp: 0, ssrc: 1, payload: Data([0, 0, 0, 0]),
                                                 arrival: 0, mediaGeneration: 1)

    /// Field 4 of the audio description in a client offer, read from the decrypted record.
    private func audioBitRate(in offer: [UInt8]) throws -> UInt64? {
        let audioLength = Int(offer[10]) << 8 | Int(offer[11])
        let plist = Data(offer[0x80 ..< 0x80 + audioLength])
        guard let dict = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let blob = dict["avcMediaStreamNegotiatorMediaBlob"] as? Data else { return nil }
        var top = ProtoIterator(try zlibDecompress([UInt8](blob), limit: 1 << 16))
        while let (field, wire, _, bytes) = top.next() {
            guard field == 3, wire == 2, let bytes else { continue }
            var description = ProtoIterator(bytes)
            while let (f, w, value, _) = description.next() { if f == 4, w == 0 { return value } }
        }
        return nil
    }

    @MainActor @Test func liveSessionRequestsMacAudioAndAuthorizesItAtTheFirstDesktop() async throws {
        try await withController { rig in
            let offer = try #require(await rig.peer.received.last { $0.first == 0x1C })
            #expect(try audioBitRate(in: offer) == 24_191)
            let lifetime = try #require(rig.controller.lifetime), audio = try #require(rig.controller.audio)
            #expect(lifetime.established && lifetime.authorization != nil)
            #expect(await eventually(.seconds(2)) { audio.snapshot.running && audio.snapshot.accepting })
            #expect(rig.audioSession.activations.load(ordering: .relaxed) == 1)
            // The fake peer sends no audio RTP: the state says waiting, never playing.
            #expect(await eventually(.seconds(2)) { await rig.controller.audioState == .negotiating })
        }
    }

    /// Close ends the lifetime and closes audio synchronously, before the
    /// trusted release of a held key is even submitted; the release then
    /// completes exactly as before.
    @MainActor @Test func closeRevokesAudioBeforeTheTrustedReleaseAndTeardown() async throws {
        try await withController { rig in
            let audio = try #require(rig.controller.audio)
            try #require(await eventually(.seconds(2)) { audio.snapshot.accepting })
            rig.view.onInput?(.key(0x61, true))
            try #require(await eventually(.seconds(2)) { await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true)] })
            rig.gate.close()
            rig.controller.stop()
            #expect(rig.controller.lifetime?.ended == true && rig.controller.lifetime?.authorization == nil)
            #expect(rig.controller.lifetime?.lastRevocation == .voluntaryClose)
            #expect(!audio.accept(Self.audioPacket))
            try #require(await eventually(.seconds(2)) { rig.gate.waiting > 0 })    // the release is parked at the writer
            #expect(await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true)])
            rig.gate.open()
            #expect(await eventually(.seconds(2)) {
                await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true), .init(key: 0x61, down: false)]
            })
            audio.sync()
            #expect(!audio.snapshot.running && rig.audioSession.deactivations.load(ordering: .relaxed) == 1)
        }
    }

    /// Transient inactivity changes nothing; true background and lock revoke
    /// audio while the session continues (its background policy is unchanged);
    /// a return to active authorizes the same, still valid session again.
    @MainActor @Test func trueBackgroundRevokesAudioAndReturnReauthorizesTheSameSession() async throws {
        try await withController { rig in
            let c = rig.controller, audio = try #require(c.audio), lifetime = try #require(c.lifetime)
            try #require(await eventually(.seconds(2)) { audio.snapshot.accepting })
            let first = try #require(lifetime.authorization)
            for signal: SceneSignal in [.willDeactivate, .didActivate, .willDeactivate, .didActivate] { c.sceneSignal(signal) }
            #expect(lifetime.authorization == first && audio.snapshot.accepting)
            c.sceneSignal(.willDeactivate)
            c.sceneSignal(.didEnterBackground)
            #expect(lifetime.authorization == nil && lifetime.lastRevocation == .background && !audio.accept(Self.audioPacket))
            audio.sync()
            #expect(!audio.snapshot.running && c.phase == .streaming)
            c.sceneSignal(.willEnterForeground)
            #expect(lifetime.authorization == nil)
            c.sceneSignal(.didActivate)
            let second = try #require(lifetime.authorization)
            #expect(second.operation > first.operation && second.session == first.session)
            #expect(await eventually(.seconds(2)) { audio.snapshot.running && audio.snapshot.accepting })
            // Device lock in the order iOS 27.2.1 reports it, with the scene active for a moment.
            for signal: SceneSignal in [.protectedDataWillBecomeUnavailable, .willDeactivate, .didActivate, .willDeactivate, .didEnterBackground] {
                c.sceneSignal(signal)
            }
            #expect(lifetime.lastRevocation == .deviceLock && lifetime.authorization == nil)
            audio.sync()
            #expect(!audio.snapshot.running)
            #expect(rig.audioSession.activations.load(ordering: .relaxed) == 2)
            #expect(rig.audioSession.deactivations.load(ordering: .relaxed) == 2)
        }
    }

    @MainActor @Test func audioMenuWaitsUntilTheSessionCanApplyItsActions() throws {
        let controller = SessionController()
        #expect(controller.audioState == nil)
        let items = try #require(AudioMenuControl(controller: controller).menu?.children as? [UIAction])
        #expect(items.count == 2 && items.allSatisfy { $0.attributes.contains(.disabled) })
    }

    @MainActor @Test(.appLifecycleExclusive) func sceneObservationFollowsTheDesktopWindowAndSeedsTheDeviceLock() throws {
        let c = SessionController(protectedDataAvailable: { false })
        let view = DesktopView(frame: .zero)
        c.attach(view)
        defer { c.stop() }
        c.start(SessionSource(id: "scene-binding", clipURL: nil), window: nil)
        #expect(view.window == nil && c.sceneState.activity == .locked)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.addSubview(view)
        let center = NotificationCenter.default
        center.post(name: UIScene.didActivateNotification, object: scene)
        #expect(c.sceneState.activity == .locked)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(c.sceneState.activity == .active)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(c.sceneState.activity == .active)   // the temporary fallback has been removed
        center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        #expect(c.sceneState.activity == .background)
        view.removeFromSuperview()
        center.post(name: UIScene.didActivateNotification, object: scene)
        #expect(c.sceneState.activity == .background)
        window.addSubview(view)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: scene)
        #expect(c.sceneState.activity == .active)
        view.removeFromSuperview()
    }

    /// Mute and Play change this session; Play is saved for this Mac only.
    @MainActor @Test func audioControlsAreTruthfulAndSaveOnlyThisMacsPreference() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vicinia-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, legacyDefaults: nil)
        let other = store.binding(host: "other.invalid", username: "tester")
        other.save(ProfilePreferences(audio: AudioPreference(enabled: true)))
        let binding = store.binding(host: Self.pinHost, username: "tester")
        try await withController(profile: binding) { rig in
            let c = rig.controller
            #expect(store.profile(binding.profileID)?.lastSuccessfulConnection != nil)   // saved at the first desktop
            try #require(await eventually(.seconds(2)) { await c.audioState == .negotiating })
            c.setAudioMuted(true)
            try #require(await eventually(.seconds(2)) { await c.audioState == .muted })
            c.setAudioMuted(false)
            c.setAudioEnabled(false)
            try #require(await eventually(.seconds(2)) { await c.audioState == .disabled })
            #expect(store.profile(binding.profileID)?.preferences.audio == AudioPreference(enabled: false))
            #expect(store.profile(other.profileID)?.preferences.audio == AudioPreference(enabled: true))
            #expect(c.preferences.audio?.enabled == false && binding.preferences.audio == nil)
            let control = AudioMenuControl(controller: c)
            #expect(control.accessibilityLabel == "Mac audio" && control.accessibilityValue == "Off")
            #expect(control.menu?.title == "Mac Audio: Off")
            let items = try #require(control.menu?.children as? [UIAction])
            #expect(items.map(\.title) == ["Play Mac Audio", "Mute"])
            #expect(items[0].state == .off && items[1].attributes.contains(.disabled))
            c.setAudioEnabled(true)
            try #require(await eventually(.seconds(2)) { await c.audioState == .negotiating })
            control.refresh()
            #expect(control.accessibilityValue == "Waiting for audio from the Mac")
            await store.flush()
        }
        #expect(store.binding(host: Self.pinHost, username: "tester").preferences.audio?.enabled == true)
    }

    /// Integration of HPSSSession.disconnect() and AudioPipeline.stopAndDrain()
    /// actor-state regression: teardown stops queued PCM immediately while decode is
    /// parked, keeps the session in `.disconnecting` (never `.idle`) and suspends
    /// concurrent `disconnect()` callers until `stopAndDrain()` completes.
    @MainActor @Test func disconnectWaitsForAudioStopAndDrainBeforeEnteringIdle() async throws {
        let entered = Atomic(false), release = DispatchSemaphore(value: 0)
        let park = Atomic(false), expired = Atomic(false)
        defer { release.signal() }
        try await withController(decodeAccessUnit: { decoder, unit in
            let block = try decoder.decode(unit)
            if park.exchange(false, ordering: .acquiringAndReleasing) {
                entered.store(true, ordering: .releasing)
                if release.wait(timeout: .now() + .seconds(5)) != .success {
                    expired.store(true, ordering: .releasing)
                }
            }
            return block
        }) { rig in
            let audio = try #require(rig.controller.audio)
            try #require(await eventually(.seconds(2)) { audio.snapshot.running && audio.snapshot.accepting })
            for i in 0..<4 {
                let pkt = AudioPacket(sequence: UInt16(i + 1), timestamp: UInt32(i * 480), ssrc: 7,
                                      payload: Data(AudioFixture.accessUnits[i]),
                                      arrival: UInt64(i) * 10_000_000, mediaGeneration: 1)
                #expect(audio.accept(pkt))
                audio.sync()
            }
            #expect(audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)
            let engine = try #require(audio.offlineEngine)
            let format = try #require(HPSSAudio.pcmFormat())
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))

            park.store(true, ordering: .releasing)
            let parkedPkt = AudioPacket(sequence: 5, timestamp: 4 * 480, ssrc: 7,
                                        payload: Data(AudioFixture.accessUnits[4]),
                                        arrival: 40_000_000, mediaGeneration: 1)
            #expect(audio.accept(parkedPkt))
            try #require(await eventually(.seconds(3)) { entered.load(ordering: .acquiring) })

            let done1 = Atomic(false), done2 = Atomic(false)
            let first = Task {
                await rig.session.disconnect()
                done1.store(true, ordering: .releasing)
            }
            try #require(await eventually(.seconds(2)) { await rig.controller.phase == .disconnecting })
            try #require(await eventually(.seconds(2)) { await rig.peer.closed })
            let second = Task {
                await rig.session.disconnect()
                done2.store(true, ordering: .releasing)
            }
            // Revocation closed admission and unscheduled queued PCM immediately, while
            // HPSSSession stays in `.disconnecting` until the audio worker drains.
            #expect(!audio.accept(Self.audioPacket))
            #expect(engine.manualRenderingSampleTime == 0)
            #expect(try engine.renderOffline(4096, to: buffer) == .success && buffer.frameLength == 4096)
            let planes = try #require(buffer.floatChannelData)
            let nonSilent = (0..<Int(buffer.frameLength)).count { abs(planes[0][$0]) > 0.001 || abs(planes[1][$0]) > 0.001 }
            #expect(nonSilent == 0)

            try await Task.sleep(for: .milliseconds(100))
            let early1 = done1.load(ordering: .acquiring), early2 = done2.load(ordering: .acquiring)
            let timedOut = expired.load(ordering: .acquiring)
            #expect(!early1 && !early2 && !timedOut)
            #expect(rig.controller.phase == .disconnecting)
            #expect(rig.controller.evidence?.value("session.teardown") == nil)

            release.signal()
            await first.value
            await second.value
            let finished1 = done1.load(ordering: .acquiring), finished2 = done2.load(ordering: .acquiring)
            #expect(finished1 && finished2)
            try #require(await eventually(.seconds(2)) { await rig.controller.phase == .idle })
            #expect(rig.controller.evidence?.value("session.teardown") != nil)
            #expect(!audio.snapshot.running && !audio.snapshot.playing && audio.snapshot.counters.scheduled == 4)
            #expect(audio.ingressReservations == (0, 0))
            #expect(rig.audioSession.deactivations.load(ordering: .relaxed) == 1)
        }
    }

    /// A replacement session gets a new generation and its own audio; the old
    /// pipeline is final and cannot be revived by a late grant.
    @MainActor @Test func aReplacementSessionHasItsOwnGenerationAndAudio() async throws {
        var previous: (generation: UInt64, audio: AudioPipeline)?
        try await withController { rig in
            previous = (try #require(rig.controller.lifetime).token.generation, try #require(rig.controller.audio))
        }
        let old = try #require(previous)
        old.audio.sync()
        #expect(!old.audio.snapshot.running && !old.audio.accept(Self.audioPacket))
        try await withController { rig in
            let lifetime = try #require(rig.controller.lifetime), audio = try #require(rig.controller.audio)
            #expect(lifetime.token.generation > old.generation && audio !== old.audio)
            old.audio.authorize(try #require(lifetime.authorization))
            old.audio.sync()
            #expect(!old.audio.snapshot.running && !old.audio.accept(Self.audioPacket))
        }
    }
}
