// Vicinia tests — clipboard through the real controller, lifetime and
// HPSSSession writer against the loopback fake host: revocation and
// saturation at the decrypted peer, the inbound and bounded-discard path, and
// single-session ownership.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import UIKit
@testable import Vicinia

/// Fails the next network send of at least `minimumBytes`: a write-side fault
/// while the read side stays up (the record already sealed is never sent).
final class SendFault: Sendable {
    private let armed = Mutex<Int?>(nil)
    func arm(minimumBytes: Int) { armed.withLock { $0 = minimumBytes } }
    func check(_ size: Int) throws {
        let fire = armed.withLock { minimum -> Bool in
            guard let bound = minimum, size >= bound else { return false }
            minimum = nil
            return true
        }
        if fire { throw ChannelError.closed("send: injected write fault") }
    }
}

/// Hands each authenticated connection to the next peer.
final class FakePeerPool: Sendable {
    let peers: [FakeControlPeer]
    private let next = Mutex(0)
    init(_ count: Int) { peers = (0..<count).map { _ in FakeControlPeer() } }
    func take() -> FakeControlPeer { next.withLock { i in defer { i += 1 }; return peers[min(i, peers.count - 1)] } }
}

@Suite("Clipboard over the live session", .serialized, .appLifecycleExclusive)
@MainActor
struct ClipboardSessionTests {
    /// Resolves to the fake host on 127.0.0.1, under its own pin entry: suites run in parallel.
    private static let pinHost = "localhost"

    final class Rig {
        let controller: SessionController
        let view: DesktopView
        let session: HPSSSession
        let peer: FakeControlPeer
        let gate: SendGate
        /// Parks only sends of 64 KiB or more: a bulk accessory write held in flight.
        let bulkGate: SendGate
        let fault: SendFault
        let channel: ControlChannel
        let base: Int
        let toolbarDefaults: TestDefaults
        init(controller: SessionController, view: DesktopView, session: HPSSSession, peer: FakeControlPeer,
             wiring: Wiring, base: Int, toolbarDefaults: TestDefaults) {
            self.controller = controller; self.view = view; self.session = session; self.peer = peer
            self.gate = wiring.gate; self.bulkGate = wiring.bulkGate; self.fault = wiring.fault; self.channel = wiring.channel
            self.base = base; self.toolbarDefaults = toolbarDefaults
        }
    }

    private func eventually(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func host(peers: FakePeerPool) async throws -> (FakeHost, UInt16) {
        try? HostKeyPinStore.forget(host: Self.pinHost)
        let host = try FakeHost(behavior: .valid)
        host.afterAuthentication = { channel, key in await peers.take().serve(channel, wrapKey: key) }
        return (host, try await host.start())
    }

    struct Wiring {
        let channel: ControlChannel
        let gate: SendGate
        let bulkGate: SendGate
        let fault: SendFault
    }

    private func controller(port: UInt16, pasteboard: FakePasteboard, slot: LiveSessionSlot,
                            defaults: TestDefaults) async -> (SessionController, Wiring) {
        let gate = SendGate(), bulkGate = SendGate(), fault = SendFault()
        let channel = ControlChannel(host: Self.pinHost, port: port)
        await channel.gateSends(bySize: { size in
            await gate.pass()
            if size >= 64 << 10 { await bulkGate.pass() }
            try fault.check(size)
        })
        let audioSession = FakeAudioSession()
        let controller = SessionController(
            channel: channel, evidence: EvidenceLog(),
            toolbar: SessionToolbar(defaults: defaults.defaults, assistiveTechnologyRunning: { false }, schedule: ManualSchedule().schedule),
            makeAudio: { AudioPipeline(enabled: $0, session: audioSession, output: .offline) },
            pasteboard: pasteboard, slot: slot)
        return (controller, Wiring(channel: channel, gate: gate, bulkGate: bulkGate, fault: fault))
    }

    private func source(automatic: Bool, claim: LiveSessionSlot.Claim? = nil) -> SessionSource {
        let binding = ProfileBinding(profileID: UUID(), preferences: ProfilePreferences(clipboard: ClipboardPreference(automaticSync: automatic)),
                                     save: { _ in }, recordSuccessfulConnection: {})
        return SessionSource(id: "clipboard-\(UUID())", clipURL: nil,
                             live: LiveRequest(host: Self.pinHost, username: "tester", password: SecretBytes("correct horse"),
                                               profile: binding, claim: claim))
    }

    /// Starts a live session up to the first presented desktop (feature grant).
    /// `beforeFirstDesktop` runs once the session exists, before that grant.
    private func live(port: UInt16, peers: FakePeerPool, peerIndex: Int, pasteboard: FakePasteboard,
                      slot: LiveSessionSlot, automatic: Bool = false, trust: Bool = true,
                      beforeFirstDesktop: (SessionController) -> Void = { _ in }) async throws -> Rig {
        let defaults = TestDefaults()
        let (controller, wiring) = await controller(port: port, pasteboard: pasteboard, slot: slot, defaults: defaults)
        let view = DesktopView(frame: .zero)
        controller.attach(view)
        Self.landscape(view)
        controller.start(source(automatic: automatic), window: nil)
        if trust {
            try #require(await eventually { controller.trustPrompt != nil })
            controller.resolveTrust(true)
        }
        try #require(await eventually { controller.phase == .awaitingRandomAccess })
        let session = try #require(controller.session)
        beforeFirstDesktop(controller)
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 2328, canvasHeight: 1200,
                                  pictureWidth: 2336, pictureHeight: 304, cropTop: 0, visibleHeight: 304)
        let mailbox = controller.mailbox
        try #require(await eventually {
            mailbox.reset(generation: 77, layout: layout)
            await session.markPresented(DesktopPresentation(generation: 77, offerID: 1, geometry: FakeControlPeer.geometry,
                                                            nanos: DispatchTime.now().uptimeNanoseconds))
            return controller.inputReady && controller.phase == .streaming
        })
        // A shown desktop gives the view's input a transform, as in the app.
        controller.renderer?.shown = DesktopSnapshot(updateSequence: 1, rtpTimestamp: 1, generation: 77, layout: layout,
                                                     stripes: [nil, nil, nil, nil], changedStripes: [], newestSubmitNanos: 0)
        let peer = peers.peers[peerIndex]
        // The first grant turns on the Mac's pasteboard monitoring, through the accessory boundary.
        try #require(await eventually { await peer.received.contains(ClipboardWire.autoPasteboardEnable) })
        return Rig(controller: controller, view: view, session: session, peer: peer, wiring: wiring,
                   base: await peer.received.count, toolbarDefaults: defaults)
    }

    private static func landscape(_ view: DesktopView) {
        view.onGeometry?(ViewportGeometry(boundsPoints: CGSize(width: 1164, height: 600), displayScale: 2, safeArea: .zero,
                                          drawablePixels: CGSize(width: 2328, height: 1200),
                                          interfaceOrientation: "landscapeRight", maximumFramesPerSecond: 60))
    }

    private func finish(_ rig: Rig) async {
        rig.gate.open()
        await rig.session.disconnect()
        rig.controller.stop()
        await rig.controller.inputTask?.value
        _ = await eventually(.seconds(3)) { rig.controller.evidence?.value("session.teardown") != nil }
        _ = await eventually(.seconds(3)) { await rig.peer.closed }
        await rig.channel.close()
        rig.toolbarDefaults.remove()
    }

    private func clipboardTexts(_ peer: FakeControlPeer, from index: Int = 0) async -> [String] {
        await peer.received.dropFirst(index).filter { $0.first == 0x1F }.compactMap { body in
            guard let items = try? ClipboardWire.decode(body),
                  let flavor = items.first?.flavors.first(where: { $0.type == ClipboardFormats.text }) else { return nil }
            return String(decoding: flavor.data, as: UTF8.self)
        }
    }

    private func message(_ text: String) throws -> [UInt8] {
        try ClipboardWire.encode([.init(flavors: [.init(type: ClipboardFormats.text, data: Array(text.utf8))])],
                                 maxMessage: HPSSSession.accessoryBudget)
    }

    private static let pasteboardChanged: [UInt8] = [0x14, 0, 0, 4, 0, 1, 0, 2]

    // MARK: both directions over the encrypted control channel

    @Test func clipboardTravelsBothWaysAndTheSessionKeepsStreaming() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)

        pasteboard.copy([[ClipboardFormats.text: Data("Da iPhone: àèì 👍".utf8)]])
        rig.controller.clipboard?.localPasteboardChanged()
        #expect(await eventually { await clipboardTexts(rig.peer, from: rig.base) == ["Da iPhone: àèì 👍"] })

        // A Mac copy larger than one record (sync-flushed, as the Mac frames it).
        let large = String((0..<180_000).map { _ in "abcdefghijklmnopqrstuvwxyzàè\n".randomElement()! })
        try await rig.peer.send(Self.pasteboardChanged)
        #expect(await eventually { await rig.peer.received.dropFirst(rig.base).contains(ClipboardWire.request) })
        let reply = ClipboardFixture.message(archive: ClipboardFixture.archive([ClipboardFixture.macText(large)]))
        #expect(reply.count > RecordLayer.maxRecordBody)
        try await rig.peer.send(reply)
        #expect(await eventually { pasteboard.items == [[ClipboardFormats.text: Data(large.utf8)]] })
        #expect(rig.controller.phase == .streaming && rig.controller.session === rig.session)
        await finish(rig)
    }

    @Test func anOversizeMacClipboardIsSkippedUnreadAndTheStreamStaysInStep() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        pasteboard.copy([[ClipboardFormats.text: Data("keep".utf8)]])
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot())

        rig.controller.receiveClipboard()
        #expect(await eventually { await rig.peer.received.dropFirst(rig.base).contains(ClipboardWire.request) })
        let size = ClipboardLimits.standard.inboundCompressed + 100_000
        var oversize = [UInt8](repeating: 0, count: 16)
        oversize[0] = 0x1F
        oversize.putU32(UInt32(size * 2), at: 8); oversize.putU32(UInt32(size), at: 12)
        oversize += (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try await rig.peer.send(oversize)
        #expect(await eventually {
            rig.controller.clipboard?.notice == .tooLargeToReceive(bytes: size, limit: ClipboardLimits.standard.inboundCompressed)
        })
        #expect(pasteboard.items == [[ClipboardFormats.text: Data("keep".utf8)]] && rig.controller.phase == .streaming)

        // The next message is parsed from its first byte: the discard ended exactly at the payload's end.
        let requests = await rig.peer.received.filter { $0 == ClipboardWire.request }.count
        rig.controller.receiveClipboard()
        #expect(await eventually { await rig.peer.received.filter { $0 == ClipboardWire.request }.count == requests + 1 })
        try await rig.peer.send(ClipboardFixture.message(archive: ClipboardFixture.archive([ClipboardFixture.macText("after")])))
        #expect(await eventually { pasteboard.items == [[ClipboardFormats.text: Data("after".utf8)]] })
        #expect(rig.controller.phase == .streaming && rig.controller.session === rig.session)
        await finish(rig)
    }

    @Test func getMacClipboardPromotesOnlyTheCurrentRequest() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        copy("local", to: pasteboard)
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard,
                                 slot: LiveSessionSlot(), automatic: true)
        let bridge = try #require(rig.controller.clipboard)
        rig.controller.sceneSignal(.didActivate)
        try await rig.peer.send(Self.pasteboardChanged)
        try #require(await eventually { await rig.peer.received.contains(ClipboardWire.request) })
        rig.controller.receiveClipboard()
        rig.controller.sceneSignal(.willDeactivate)
        pasteboard.advanceChangeCount(by: 2)
        try await rig.peer.send(try message("requested"))
        #expect(await eventually { !bridge.hasRequestInFlight })
        #expect(bridge.notice == .copiedFromMac)
        #expect(pasteboard.items == [[ClipboardFormats.text: Data("requested".utf8)]] && pasteboard.writes == 1)
        #expect(await rig.peer.received.filter { $0 == ClipboardWire.request }.count == 1)

        try await rig.peer.send(Self.pasteboardChanged)
        try #require(await eventually { await rig.peer.received.filter { $0 == ClipboardWire.request }.count == 2 })
        pasteboard.advanceChangeCount(by: 2)
        try await rig.peer.send(try message("automatic"))
        #expect(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.items == [[ClipboardFormats.text: Data("requested".utf8)]] && pasteboard.writes == 1)
        #expect(pasteboard.reads == 0)
        #expect(await rig.peer.received.filter { $0 == ClipboardWire.request }.count == 2)
        await finish(rig)
    }

    // MARK: Revocation at the decrypted peer

    enum Revocation: String, CaseIterable, Sendable { case deviceLock, background, close, featureCancel }

    @Test(arguments: Revocation.allCases)
    func revocationSealsNoQueuedAccessoryWriteAndTheReleaseStillCompletes(_ revocation: Revocation) async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot())
        let session = rig.session
        let token = try #require(rig.controller.lifetime?.authorization).accessoryToken

        // A held key: its trusted release must follow whatever was already submitted.
        await session.dispatchInput(.key(0x61, true), epoch: rig.controller.inputEpoch)
        #expect(await eventually { await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x61, down: true)] })
        let mark = await rig.peer.received.count

        rig.gate.close()
        let submitted = try message("A: already submitted")
        let first = Task { await session.sendAccessory(submitted, token: token, producer: .clipboard) }
        #expect(await eventually { rig.gate.waiting == 1 })                 // sealed and parked in the network send
        let second = Task { [b = try message("B: queued")] in await session.sendAccessory(b, token: token, producer: .init(name: "synthetic-1")) }
        let third = Task { [c = try message("C: queued")] in await session.sendAccessory(c, token: token, producer: .init(name: "synthetic-2")) }
        #expect(await eventually { await session.queuedAccessories == 2 })

        switch revocation {
        case .deviceLock: rig.controller.sceneSignal(.protectedDataWillBecomeUnavailable)
        case .background:
            rig.controller.sceneSignal(.didEnterBackground)
            rig.controller.sceneSignal(.didActivate)                         // a new grant at once: B and C carry the old one
            #expect(rig.controller.lifetime?.authorization?.accessoryToken != token)
        case .close: rig.controller.stop()
        case .featureCancel:
            session.accessoryGate.revoke()
            await session.purgeAccessories()
        }
        if revocation != .close { rig.view.cancelInput() }                   // the focus-loss release of the platform
        let secondOutcome = await second.value, thirdOutcome = await third.value
        #expect(secondOutcome == .cancelled && thirdOutcome == .cancelled)
        rig.gate.open()
        #expect(await first.value == .submitted)                             // possibly delivered, never recalled
        #expect(await eventually { await rig.peer.keyEvents(from: mark) == [.init(key: 0x61, down: false)] })

        // At the peer: A, then the release; B and C were never sealed.
        let after = await rig.peer.received.dropFirst(mark)
        let order = after.compactMap { body -> String? in
            if body.first == 0x1F { return (try? ClipboardWire.decode(body)).map { String(decoding: $0[0].flavors[0].data, as: UTF8.self) } }
            return body.first == 4 && body[1] == 0 ? "release" : nil
        }
        #expect(order == ["A: already submitted", "release"])
        #expect(await clipboardTexts(rig.peer).allSatisfy { !$0.hasPrefix("B") && !$0.hasPrefix("C") })
        // Nothing stale on a new generation: a later write with the old token is refused unsent.
        #expect(await session.sendAccessory(try message("D: stale"), token: token, producer: .clipboard) != .submitted)
        await finish(rig)
        #expect(await clipboardTexts(rig.peer).filter { $0.hasPrefix("D") }.isEmpty)
    }

    // MARK: Accessory queue saturation

    @Test func accessorySaturationNeverFailsTheSessionOrDelaysInputForever() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot())
        let session = rig.session, epoch = rig.controller.inputEpoch
        let token = try #require(rig.controller.lifetime?.authorization).accessoryToken

        rig.gate.close()
        let poll = Task { await session.pollCursor() }
        #expect(await eventually { rig.gate.waiting == 1 })
        let bulk = [UInt8](repeating: 0x1F, count: 700 << 10)
        let queued = Task { await session.sendAccessory(bulk, token: token, producer: .init(name: "bulk-1")) }
        #expect(await eventually { await session.queuedAccessories == 1 })
        // Admission refuses, before the writer, what would eat the headroom of input and transitions.
        #expect(await session.sendAccessory([UInt8](repeating: 0x1F, count: 100 << 10), token: token, producer: .init(name: "bulk-2")) == .busy)
        #expect(await session.sendAccessory([0x1F], token: token, producer: .init(name: "bulk-1")) == .busy)
        #expect(await session.sendAccessory([UInt8](repeating: 0x1F, count: HPSSSession.accessoryBudget + 1), token: token,
                                            producer: .init(name: "bulk-3")) == .tooLarge(limit: HPSSSession.accessoryBudget))
        // The bridge reports an oversize clipboard as a limitation.
        let noise = String((0..<(1_400 << 10)).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/".randomElement()! })
        pasteboard.copy([[ClipboardFormats.text: Data(noise.utf8)]])
        rig.controller.sendClipboard(pasteboard.pasteControlProviders)
        #expect(await eventually(.seconds(10)) {
            if case .tooLargeToSend = rig.controller.clipboard?.notice { return true } else { return false }
        })

        let down = Task { await session.dispatchInput(.key(0x62, true), epoch: epoch) }
        let up = Task { await session.dispatchInput(.key(0x62, false), epoch: epoch) }
        let release = Task { await session.releaseInputForOverflow(epoch: epoch) }
        let poll2 = Task { await session.pollCursor() }
        #expect(await eventually { await session.pendingWrites >= 5 })   // bulk, down, up, release, poll (+ timer polls)
        #expect(rig.controller.phase == .streaming && rig.controller.evidence?.value("session.failure") == nil)

        rig.gate.open()
        await poll.value; await down.value; await up.value; await poll2.value
        let queuedOutcome = await queued.value, released = await release.value
        #expect(queuedOutcome == .submitted && released)
        #expect(await eventually { await rig.peer.keyEvents(from: rig.base) == [.init(key: 0x62, down: true), .init(key: 0x62, down: false)] })
        #expect(rig.controller.phase == .streaming && rig.controller.session === session)
        #expect(rig.controller.evidence?.value("session.failure") == nil)
        await finish(rig)
    }

    // MARK: Single-session ownership

    @Test func aSecondLiveRequestIsRefusedWithoutSideEffects() async throws {
        let peers = FakePeerPool(2), pasteboard = FakePasteboard(), slot = LiveSessionSlot()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: slot)
        #expect(rig.controller.holdsIdleTimer)

        let defaults = TestDefaults()
        defer { defaults.remove() }
        let (other, otherWiring) = await controller(port: port, pasteboard: pasteboard, slot: slot, defaults: defaults)
        let otherChannel = otherWiring.channel
        other.attach(DesktopView(frame: .zero))
        other.start(source(automatic: true), window: nil)
        #expect(other.phase == .failed && other.session == nil && other.clipboard == nil)
        #expect(other.status.contains("Another Mac session is open"))
        try await Task.sleep(for: .milliseconds(300))
        let otherState = await otherChannel.lastStateDescription
        #expect(host.proofs.all.count == 1 && otherState == "setup")
        // The process-wide idle timer is shared with parallel suites: assert ownership instead.
        #expect(!other.holdsIdleTimer)                                       // never taken, so never reset by stop()
        other.stop()
        #expect(rig.controller.phase == .streaming && slot.isLive)
        await finish(rig)
        #expect(await eventually { !slot.isLive && !slot.isTearingDown })
    }

    @Test func aSuccessorConnectsOnlyAfterThePredecessorsTeardownCompleted() async throws {
        let peers = FakePeerPool(2), pasteboard = FakePasteboard(), slot = LiveSessionSlot()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let first = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: slot)
        await first.session.dispatchInput(.key(0x63, true), epoch: first.controller.inputEpoch)
        #expect(await eventually { await first.peer.keyEvents(from: first.base) == [.init(key: 0x63, down: true)] })

        first.gate.close()                                  // the trusted release parks: teardown cannot complete
        first.controller.stop()
        #expect(slot.isTearingDown && !slot.isLive)

        let defaults = TestDefaults()
        defer { defaults.remove() }
        let (second, secondWiring) = await controller(port: port, pasteboard: pasteboard, slot: slot, defaults: defaults)
        let secondChannel = secondWiring.channel
        let view = DesktopView(frame: .zero)
        second.attach(view)
        Self.landscape(view)
        second.start(source(automatic: false), window: nil)
        #expect(second.phase == .connecting)                // accepted, waiting
        try await Task.sleep(for: .milliseconds(500))
        let secondState = await secondChannel.lastStateDescription
        #expect(second.session == nil && host.proofs.all.count == 1 && secondState == "setup")

        first.gate.open()
        #expect(await eventually { second.session != nil })
        #expect(first.controller.evidence?.value("session.teardown") != nil) // completed before the successor existed
        // Same host and pin; a prompt is answered if one appears. The successor binds media and negotiates.
        #expect(await eventually {
            if second.trustPrompt != nil { second.resolveTrust(true) }
            return second.phase == .awaitingRandomAccess
        })
        #expect(await first.peer.keyEvents(from: first.base).last == .init(key: 0x63, down: false))
        let successor = try #require(second.session)
        await successor.disconnect()
        second.stop()
        await secondChannel.close()
        _ = await eventually(.seconds(3)) { second.evidence?.value("session.teardown") != nil }
        await first.channel.close()
        first.toolbarDefaults.remove()
        #expect(await eventually { !slot.isLive && !slot.isTearingDown })
    }

    // MARK: Device lock after a background revocation

    @Test func aCopyMadeBeforeOrDuringALockIsNeverUploadedOnReturn() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.willDeactivate)
        controller.sceneSignal(.didEnterBackground)                          // revoked: background
        pasteboard.copy([[ClipboardFormats.text: Data("copied in the background".utf8)]])
        controller.clipboard?.localPasteboardChanged()
        controller.sceneSignal(.protectedDataWillBecomeUnavailable)          // then locked, while already revoked
        pasteboard.copy([[ClipboardFormats.text: Data("copied while locked".utf8)]])
        controller.sceneSignal(.protectedDataDidBecomeAvailable)
        controller.sceneSignal(.willEnterForeground)
        controller.sceneSignal(.didActivate)
        #expect(controller.lifetime?.authorization != nil && controller.clipboard?.isAuthorized == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await clipboardTexts(rig.peer, from: rig.base).isEmpty && pasteboard.reads == 0)
        // Automatic sending works again for a copy made after the return.
        pasteboard.copy([[ClipboardFormats.text: Data("after the return".utf8)]])
        controller.clipboard?.localPasteboardChanged()
        #expect(await eventually { await clipboardTexts(rig.peer, from: rig.base) == ["after the return"] })
        #expect(controller.phase == .streaming)
        await finish(rig)
    }

    // MARK: Rate-limited change-count checks
    // Each test stays well under 10 s of streaming: the fake host sends no
    // media, and the session's media watchdog ends a session after 10 s without.

    /// Longer than the longest gap between two checks on the 0.5 s timer (1.5 s).
    private static let quiet: Duration = .milliseconds(1_600)

    private func copy(_ text: String, to pasteboard: FakePasteboard) {
        pasteboard.copy([[ClipboardFormats.text: Data(text.utf8)]])          // another app: no notification
    }

    /// Waits until the session timer has handed `count` more checks to the bridge.
    private func checks(_ count: Int, after rig: Rig, timeout: Duration = .seconds(4)) async -> Bool {
        let target = rig.controller.clipboardChecks + count
        return await eventually(timeout) { rig.controller.clipboardChecks >= target }
    }

    /// Texts of the clipboard messages the Mac received, each reassembled from
    /// its records first: a message larger than one record spans several.
    private func texts(_ rig: Rig) async -> [String] {
        var bodies = Array(await rig.peer.received.dropFirst(rig.base))[...]
        var texts: [String] = []
        while let body = bodies.popFirst() {
            guard body.first == 0x1F, let header = try? ClipboardWire.Header(body) else { continue }
            var message = body
            while message.count < ClipboardWire.headerLength + header.compressed, let next = bodies.popFirst() { message += next }
            guard let items = try? ClipboardWire.decode(message),
                  let text = items.first?.flavors.first(where: { $0.type == ClipboardFormats.text }) else { continue }
            texts.append(String(decoding: text.data, as: UTF8.self))
        }
        return texts
    }

    /// Another app copies while the session stays active and nothing
    /// is posted; the check alone reads it once and sends it, and later checks
    /// of the unchanged clipboard read nothing.
    @Test func anotherAppsCopyIsSentWithoutANotificationOrAnActivation() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        rig.controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        copy("from a shortcut", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["from a shortcut"] })
        #expect(pasteboard.reads == 1)
        #expect(await checks(2, after: rig))
        #expect(await texts(rig) == ["from a shortcut"] && pasteboard.reads == 1)
        #expect(rig.controller.phase == .streaming)
        await finish(rig)
    }

    /// The clipboard at the first grant is the baseline: never read or sent,
    /// however many checks follow, and the checks are at most one a second.
    @Test func anUnchangedClipboardIsNeverReadAndIsCheckedAtMostOnceASecond() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        copy("before the session", to: pasteboard)
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        rig.controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        let start = ContinuousClock.now, first = rig.controller.clipboardChecks
        try await Task.sleep(for: .milliseconds(3_200))
        let made = rig.controller.clipboardChecks - first
        let elapsed = Int((ContinuousClock.now - start).components.seconds)
        #expect(made >= 1 && made <= elapsed + 1, "\(made) checks in \(elapsed) s")
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
        await finish(rig)
    }

    /// Control Center or the paste prompt: transient inactivity keeps the grant,
    /// so the check itself stops; the return to active reads the copy once.
    @Test func noCheckRunsWhileTheSceneIsInactive() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        let made = controller.clipboardChecks
        copy("while inactive", to: pasteboard)
        try await Task.sleep(for: Self.quiet)
        #expect(await texts(rig).isEmpty && controller.clipboardChecks == made && pasteboard.reads == 0)
        #expect(controller.clipboard?.isAuthorized == true)                  // still granted: only the scene held it back
        controller.sceneSignal(.didActivate)
        #expect(await eventually { await texts(rig) == ["while inactive"] })
        #expect(await checks(1, after: rig))
        #expect(await texts(rig) == ["while inactive"] && pasteboard.reads == 1)   // once, not again by a check
        await finish(rig)
    }

    /// True background revokes: no check runs. A background copy is sent once
    /// on return. Later checks do not read the same copy again.
    @Test func noCheckRunsInTheBackgroundAndABackgroundCopyIsSentOnceOnReturn() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        controller.sceneSignal(.didEnterBackground)
        let made = controller.clipboardChecks
        copy("in the background", to: pasteboard)
        try await Task.sleep(for: Self.quiet)
        #expect(controller.clipboardChecks == made && pasteboard.reads == 0 && controller.clipboard?.isAuthorized == false)
        controller.sceneSignal(.willEnterForeground)
        controller.sceneSignal(.didActivate)
        #expect(await eventually { await texts(rig) == ["in the background"] })
        #expect(await checks(1, after: rig))
        #expect(await texts(rig) == ["in the background"] && pasteboard.reads == 1)
        await finish(rig)
    }

    /// A device lock revokes and resets: no check runs while locked, and after
    /// the unlock nothing copied before it is uploaded by a check; a later copy is.
    @Test func noCheckRunsWhileLockedAndNothingEarlierIsUploadedAfterTheUnlock() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        controller.sceneSignal(.protectedDataWillBecomeUnavailable)          // locked from the session
        controller.sceneSignal(.didEnterBackground)
        let made = controller.clipboardChecks
        copy("while locked", to: pasteboard)
        try await Task.sleep(for: Self.quiet)
        #expect(controller.clipboardChecks == made && pasteboard.reads == 0 && controller.clipboard?.isAuthorized == false)
        controller.sceneSignal(.protectedDataDidBecomeAvailable)
        controller.sceneSignal(.willEnterForeground)
        controller.sceneSignal(.didActivate)
        #expect(controller.clipboard?.isAuthorized == true)
        #expect(await checks(1, after: rig))
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
        copy("after the unlock", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["after the unlock"] })
        #expect(pasteboard.reads == 1 && controller.phase == .streaming)
        await finish(rig)
    }

    /// Sync Automatically off: no check at all, the paste control still sends.
    /// Turned on, only later copies are sent; turned off, the checks stop.
    @Test func withSyncAutomaticallyOffNothingIsCheckedAndManualSendStillWorks() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: false)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)

        copy("not automatic", to: pasteboard)
        try await Task.sleep(for: Self.quiet)
        #expect(await texts(rig).isEmpty && controller.clipboardChecks == 0 && pasteboard.reads == 0)
        controller.sendClipboard(pasteboard.pasteControlProviders)          // the system paste control
        #expect(await eventually { await texts(rig) == ["not automatic"] })
        #expect(pasteboard.reads == 0)

        controller.setClipboardAutomaticSync(true)
        #expect(await checks(1, after: rig))
        #expect(await texts(rig) == ["not automatic"] && pasteboard.reads == 0)
        copy("after turning it on", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["not automatic", "after turning it on"] })

        controller.setClipboardAutomaticSync(false)
        let made = controller.clipboardChecks
        copy("after turning it off", to: pasteboard)
        try await Task.sleep(for: Self.quiet)
        #expect(await texts(rig).count == 2 && controller.clipboardChecks == made && pasteboard.reads == 1)
        await finish(rig)
    }

    /// Every new session starts from the clipboard as it is: a copy made
    /// before or between sessions is never uploaded by the next one.
    @Test func aReconnectedSessionStartsFromABaselineAndSendsOnlyLaterCopies() async throws {
        let peers = FakePeerPool(2), pasteboard = FakePasteboard()
        copy("before the first session", to: pasteboard)
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let first = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        first.controller.sceneSignal(.didActivate)
        try #require(await checks(2, after: first))
        #expect(await texts(first).isEmpty && pasteboard.reads == 0)
        copy("during the first session", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(first) == ["during the first session"] })
        await finish(first)

        copy("between the sessions", to: pasteboard)
        try? HostKeyPinStore.forget(host: Self.pinHost)                      // the same trust prompt as the first time
        let second = try await live(port: port, peers: peers, peerIndex: 1, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        second.controller.sceneSignal(.didActivate)
        try #require(await checks(2, after: second))
        #expect(await texts(second).isEmpty && pasteboard.reads == 1)
        copy("during the second session", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(second) == ["during the second session"] })
        #expect(pasteboard.reads == 2)
        await finish(second)
    }

    /// Anti-echo: a Mac copy written here is never sent back by a check.
    @Test func aMacCopyAppliedHereIsNeverSentBackByTheCheck() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        rig.controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        try await rig.peer.send(Self.pasteboardChanged)                    // the Mac copied
        #expect(await eventually { await rig.peer.received.dropFirst(rig.base).contains(ClipboardWire.request) })
        try await rig.peer.send(ClipboardFixture.message(archive: ClipboardFixture.archive([ClipboardFixture.macText("from the Mac")])))
        #expect(await eventually { pasteboard.items == [[ClipboardFormats.text: Data("from the Mac".utf8)]] })
        #expect(pasteboard.writes == 1)
        #expect(await checks(2, after: rig))
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
        copy("later, on this iPhone", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["later, on this iPhone"] })
        await finish(rig)
    }

    /// A refused paste pauses automatic sending: one prompt, never repeated by
    /// the checks; the paste control still sends.
    @Test func aRefusedReadPausesAutomaticSendingWithoutAnotherPromptFromTheChecks() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        pasteboard.allowsRead = false                                        // the user did not allow paste
        copy("refused", to: pasteboard)
        #expect(await eventually(.seconds(3)) { controller.clipboard?.automaticReadPaused == true })
        #expect(pasteboard.reads == 1 && controller.clipboard?.notice == .automaticSendPaused)
        copy("refused again", to: pasteboard)
        #expect(await checks(2, after: rig))
        #expect(await texts(rig).isEmpty && pasteboard.reads == 1)
        controller.sendClipboard(pasteboard.pasteControlProviders)
        #expect(await eventually { await texts(rig) == ["refused again"] })
        #expect(pasteboard.reads == 1)
        await finish(rig)
    }

    /// A copy made while a send is still in flight is not read meanwhile; the
    /// newest is read and sent once after it.
    @Test func aCopyArrivingDuringAnotherSendIsSentOnceAfterIt() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        rig.controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        rig.bulkGate.close()                                                 // parks network sends of 64 KiB or more
        let large = String((0..<120_000).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/".randomElement()! })
        copy(large, to: pasteboard)
        #expect(await eventually(.seconds(3)) { rig.bulkGate.waiting == 1 })   // handed to the network, still in flight
        #expect(pasteboard.reads == 1)
        copy("newer", to: pasteboard)
        #expect(await checks(1, after: rig))
        copy("newest", to: pasteboard)
        #expect(pasteboard.reads == 1)                                       // nothing read while sending
        rig.bulkGate.open()
        #expect(await eventually(.seconds(3)) { await texts(rig).count == 2 })
        #expect(await texts(rig) == [large, "newest"] && pasteboard.reads == 2)
        #expect(await checks(1, after: rig))
        #expect(await texts(rig).count == 2 && pasteboard.reads == 2)
        await finish(rig)
    }

    // MARK: Live-session baseline and active-scene eligibility
    // A posted changedNotification reaches the controller on the main queue at
    // once (each test checks this first); deferred work is drained in order.

    private func notifyClipboardChanged() {
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: nil)
    }

    /// Runs the main-actor jobs already enqueued (they run in order), without a delay.
    private func drain() async { for _ in 0..<3 { await Task { @MainActor in }.value } }

    /// Sync Automatically turned on while the session connects, before
    /// the first grant. Nothing copied before the first desktop is read or
    /// uploaded, by the grant or by the checks; a later copy is.
    @Test func syncTurnedOnBeforeTheFirstDesktopNeverUploadsWhatWasCopiedBefore() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        var unauthorizedBefore = false
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(),
                                 automatic: false) { controller in
            unauthorizedBefore = controller.clipboard?.isAuthorized == false
            controller.setClipboardAutomaticSync(true)                       // before the first grant
            pasteboard.copy([[ClipboardFormats.text: Data("before the first desktop".utf8)]])
            NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: nil)
        }
        let controller = rig.controller
        #expect(unauthorizedBefore && controller.clipboard?.isAuthorized == true)
        controller.sceneSignal(.didActivate)
        #expect(await checks(2, after: rig))
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
        copy("after the first desktop", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["after the first desktop"] })
        #expect(pasteboard.reads == 1)
        await finish(rig)
    }

    /// Toggled after an unlock but before the return re-authorizes:
    /// nothing copied before the return is uploaded; a later copy is.
    @Test func aToggleAfterAnUnlockBeforeTheReturnNeverUploadsWhatWasCopiedBefore() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        controller.sceneSignal(.protectedDataWillBecomeUnavailable)          // locked: memory reset
        controller.sceneSignal(.didEnterBackground)
        copy("while locked", to: pasteboard)
        controller.sceneSignal(.protectedDataDidBecomeAvailable)             // unlocked, not yet re-granted
        controller.setClipboardAutomaticSync(false)
        controller.setClipboardAutomaticSync(true)
        copy("after the unlock, before the return", to: pasteboard)
        #expect(controller.clipboard?.isAuthorized == false)
        controller.sceneSignal(.willEnterForeground)
        controller.sceneSignal(.didActivate)                                  // the new grant: a fresh baseline
        #expect(controller.clipboard?.isAuthorized == true)
        #expect(await checks(2, after: rig))
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
        copy("after the return", to: pasteboard)
        #expect(await eventually(.seconds(3)) { await texts(rig) == ["after the return"] })
        #expect(pasteboard.reads == 1)
        await finish(rig)
    }

    /// A changedNotification while the scene is inactive (Control
    /// Center, the paste prompt) reads nothing; while active it reads at once.
    /// The return to active reads the change exactly once.
    @Test func aClipboardNotificationWhileTheSceneIsInactiveReadsNothing() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        copy("while active", to: pasteboard)
        notifyClipboardChanged()
        #expect(pasteboard.reads == 1)                                       // delivered and read at once
        #expect(await eventually { await texts(rig) == ["while active"] })
        controller.sceneSignal(.willDeactivate)
        copy("while inactive", to: pasteboard)
        notifyClipboardChanged()
        #expect(pasteboard.reads == 1)                                       // not while inactive
        await drain()
        #expect(pasteboard.reads == 1 && controller.clipboard?.isAuthorized == true)
        controller.sceneSignal(.didActivate)
        #expect(await eventually { await texts(rig) == ["while active", "while inactive"] })
        #expect(await checks(1, after: rig))
        #expect(pasteboard.reads == 2)                                       // once
        await finish(rig)
    }

    /// An activation followed at once by a deactivation, before the
    /// deferred read runs (from inactive, or from the background with its
    /// re-grant's own deferred read): nothing is read. The next activation
    /// reads the change exactly once.
    @Test(arguments: ["inactive", "background"])
    func anActivationEndedAtOnceByADeactivationReadsNothing(_ from: String) async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        if from == "background" { controller.sceneSignal(.didEnterBackground) }
        copy("meanwhile", to: pasteboard)
        if from == "background" { controller.sceneSignal(.willEnterForeground) }
        controller.sceneSignal(.didActivate)                                  // deferred reads are scheduled
        controller.sceneSignal(.willDeactivate)                               // before they run
        await drain()
        #expect(pasteboard.reads == 0 && controller.clipboard?.isAuthorized == true)
        controller.sceneSignal(.didActivate)
        #expect(await eventually { await texts(rig) == ["meanwhile"] })
        #expect(await checks(1, after: rig))
        #expect(await texts(rig) == ["meanwhile"] && pasteboard.reads == 1)  // exactly one eligible read
        await finish(rig)
    }

    /// In the background, while locked and after the end, neither a
    /// notification nor an activation reads.
    @Test func noAutomaticReadStartsInTheBackgroundWhileLockedOrAfterTheEnd() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        controller.sceneSignal(.didActivate)
        try #require(await checks(1, after: rig))

        controller.sceneSignal(.willDeactivate)
        controller.sceneSignal(.didEnterBackground)
        copy("in the background", to: pasteboard)
        notifyClipboardChanged()
        await drain()
        #expect(pasteboard.reads == 0)
        controller.sceneSignal(.protectedDataWillBecomeUnavailable)
        copy("while locked", to: pasteboard)
        notifyClipboardChanged()
        await drain()
        #expect(pasteboard.reads == 0)
        await finish(rig)
        copy("after the end", to: pasteboard)
        notifyClipboardChanged()
        controller.sceneSignal(.protectedDataDidBecomeAvailable)
        controller.sceneSignal(.didActivate)
        await drain()
        #expect(await texts(rig).isEmpty && pasteboard.reads == 0)
    }

    enum ClipboardBoundary: Sendable { case inactive, background, lock, disconnect, failure, close }

    @Test(arguments: [ClipboardBoundary.inactive, .background, .lock, .disconnect, .failure, .close])
    func clipboardReadRespectsTheSessionBoundary(_ boundary: ClipboardBoundary) async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard,
                                 slot: LiveSessionSlot(), automatic: true)
        let controller = rig.controller
        defer { controller.stop(); pasteboard.probe.release() }
        let bridge = try #require(controller.clipboard)
        controller.sceneSignal(.didActivate)
        pasteboard.probe.hold()
        copy("old provider", to: pasteboard)
        notifyClipboardChanged()
        try #require(await clipboardReached { pasteboard.probe.parkedLoads == 1 })
        controller.sceneSignal(.willDeactivate)
        switch boundary {
        case .inactive:
            #expect(bridge.isAuthorized && bridge.isSending)
            pasteboard.probe.release()
            #expect(await eventually { await texts(rig) == ["old provider"] })
        case .background, .lock:
            if boundary == .background {
                controller.sceneSignal(.didEnterBackground)
            } else {
                controller.sceneSignal(.protectedDataWillBecomeUnavailable)
            }
            #expect(!bridge.isAuthorized && !bridge.isSending)
            if boundary == .background {
                controller.sceneSignal(.willEnterForeground)
            } else {
                controller.sceneSignal(.protectedDataDidBecomeAvailable)
            }
            controller.sceneSignal(.didActivate)
            try #require(bridge.isAuthorized)
            controller.sendClipboard(pasteboard.pasteControlProviders)
            try #require(await clipboardReached { pasteboard.probe.parkedLoads == 2 })
            #expect(bridge.isSending && pasteboard.reads == 1)
            pasteboard.probe.release()
            #expect(await eventually { await texts(rig) == ["old provider"] && bridge.notice == .sentToMac })
        case .disconnect, .failure, .close:
            if boundary == .disconnect {
                await rig.session.disconnect()
            } else if boundary == .failure {
                let token = try #require(controller.lifetime?.authorization).accessoryToken
                rig.fault.arm(minimumBytes: 64 << 10)
                let outcome = await rig.session.sendAccessory([UInt8](repeating: 0x1F, count: 100 << 10),
                                                              token: token, producer: .clipboard)
                #expect(outcome == .failed)
            } else {
                controller.stop()
            }
            #expect(await clipboardReached { !bridge.isAuthorized && !bridge.isSending })
            pasteboard.probe.release()
            await drain()
            #expect(await texts(rig).isEmpty)
        }
        await finish(rig)
    }

    // MARK: Accessory budget and terminal write failures

    @Test func anAccessoryWriteInFlightStillCountsAgainstTheAccessoryBudget() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot())
        let session = rig.session
        let token = try #require(rig.controller.lifetime?.authorization).accessoryToken
        rig.bulkGate.close()
        let first = Task { await session.sendAccessory([UInt8](repeating: 0x1F, count: 700 << 10), token: token, producer: .init(name: "bulk-1")) }
        #expect(await eventually { rig.bulkGate.waiting == 1 })             // sealed, out of the queue, in the network send
        #expect(await session.queuedAccessories == 0)
        // 700 KiB in flight + 100 KiB is over the 768 KiB budget, although the queue is empty.
        let second = Task { await session.sendAccessory([UInt8](repeating: 0x1F, count: 100 << 10), token: token, producer: .init(name: "bulk-2")) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await session.queuedAccessories == 0)                        // never admitted behind it
        rig.bulkGate.open()
        #expect(await first.value == .submitted)
        #expect(await second.value == .busy)
        #expect(await session.sendAccessory([UInt8](repeating: 0x1F, count: 100 << 10), token: token, producer: .init(name: "bulk-2")) == .submitted)
        #expect(rig.controller.phase == .streaming && rig.controller.evidence?.value("session.failure") == nil)
        await finish(rig)
    }

    @Test func aFailedAccessoryWriteTakesTheSessionFailurePathButAdmissionRefusalsDoNot() async throws {
        let peers = FakePeerPool(1), pasteboard = FakePasteboard()
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let rig = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: LiveSessionSlot())
        let session = rig.session
        let token = try #require(rig.controller.lifetime?.authorization).accessoryToken
        // Admission refusals are limitations, never failures.
        #expect(await session.sendAccessory([UInt8](repeating: 0x1F, count: HPSSSession.accessoryBudget + 1), token: token,
                                            producer: .clipboard) == .tooLarge(limit: HPSSSession.accessoryBudget))
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.controller.phase == .streaming && rig.controller.evidence?.value("session.failure") == nil)
        // A failed network handoff of a sealed accessory record, with the read side still up: terminal.
        rig.fault.arm(minimumBytes: 64 << 10)
        let outcome = await session.sendAccessory([UInt8](repeating: 0x1F, count: 100 << 10), token: token, producer: .clipboard)
        #expect(outcome == .failed)
        #expect(await eventually { rig.controller.phase == .failed })
        #expect(rig.controller.evidence?.value("session.failure")?.contains("injected write fault") == true)
        await finish(rig)
    }

    // MARK: Ownership at the session boundary

    @Test func aStartupFailureBeforeAnySessionReleasesTheSlotAtOnce() async throws {
        let slot = LiveSessionSlot(), pasteboard = FakePasteboard(), defaults = TestDefaults()
        defer { defaults.remove() }
        let (controller, wiring) = await controller(port: 9, pasteboard: pasteboard, slot: slot, defaults: defaults)
        controller.attach(DesktopView(frame: .zero))                          // no geometry: display setup fails
        controller.start(source(automatic: false), window: nil)
        #expect(slot.isLive)
        #expect(await eventually { controller.phase == .failed })
        #expect(controller.session == nil && controller.status.contains("Display setup is unavailable"))
        #expect(!slot.isLive && !slot.isTearingDown)                          // without waiting for Close
        let next = try #require(slot.claim())
        slot.finish(next)
        controller.stop()
        await wiring.channel.close()
    }

    @Test func aSuccessorGivesUpExplicitlyWhenThePredecessorsTeardownDoesNotComplete() async throws {
        let peers = FakePeerPool(2), pasteboard = FakePasteboard(), slot = LiveSessionSlot(predecessorTimeout: .milliseconds(600))
        let (host, port) = try await host(peers: peers)
        defer { host.stop(); try? HostKeyPinStore.forget(host: Self.pinHost) }
        let first = try await live(port: port, peers: peers, peerIndex: 0, pasteboard: pasteboard, slot: slot)
        await first.session.dispatchInput(.key(0x64, true), epoch: first.controller.inputEpoch)
        #expect(await eventually { await first.peer.keyEvents(from: first.base) == [.init(key: 0x64, down: true)] })
        first.gate.close()                                                    // the trusted release parks: teardown cannot complete
        first.controller.stop()
        #expect(slot.isTearingDown && !slot.isLive)

        let defaults = TestDefaults()
        defer { defaults.remove() }
        let (second, secondWiring) = await controller(port: port, pasteboard: pasteboard, slot: slot, defaults: defaults)
        let view = DesktopView(frame: .zero)
        second.attach(view)
        Self.landscape(view)
        second.start(source(automatic: false), window: nil)
        #expect(await eventually(.seconds(5)) { second.phase == .failed })
        #expect(second.status.contains("still closing") && second.session == nil && host.proofs.all.count == 1)
        #expect(!slot.isLive && slot.isTearingDown)                           // its own claim released; the predecessor still owns the ports
        // A wait closed before it ends returns at once and frees its claim.
        let (third, thirdWiring) = await controller(port: port, pasteboard: pasteboard, slot: slot, defaults: defaults)
        let thirdView = DesktopView(frame: .zero)
        third.attach(thirdView)
        Self.landscape(thirdView)
        third.start(source(automatic: false), window: nil)
        #expect(slot.isLive)
        third.stop()
        #expect(!slot.isLive)

        first.gate.open()
        #expect(await eventually { !slot.isTearingDown })
        second.stop()
        await secondWiring.channel.close()
        await thirdWiring.channel.close()
        _ = await eventually(.seconds(3)) { first.controller.evidence?.value("session.teardown") != nil }
        await first.channel.close()
        first.toolbarDefaults.remove()
    }

    @Test func theSessionBoundaryAdoptsOnlyAClaimTheSlotStillHolds() async throws {
        let slot = LiveSessionSlot(), pasteboard = FakePasteboard(), defaults = TestDefaults()
        defer { defaults.remove() }
        // Reserved where the request was made: adopted, not claimed again.
        let reserved = try #require(slot.claim())
        let (adopting, wiringA) = await controller(port: 9, pasteboard: pasteboard, slot: slot, defaults: defaults)
        adopting.attach(DesktopView(frame: .zero))
        adopting.start(source(automatic: false, claim: reserved), window: nil)
        #expect(adopting.phase == .connecting && adopting.holdsIdleTimer && slot.holds(reserved))
        adopting.stop()
        #expect(!slot.isLive && !slot.isTearingDown)                          // no session was created: released at once
        // A claim the slot no longer holds is refused at the boundary, before any side effect.
        let stale = try #require(slot.claim())
        slot.finish(stale)
        let (refused, wiringB) = await controller(port: 9, pasteboard: pasteboard, slot: slot, defaults: defaults)
        refused.attach(DesktopView(frame: .zero))
        refused.start(source(automatic: false, claim: stale), window: nil)
        #expect(refused.phase == .failed && !refused.holdsIdleTimer && refused.session == nil && refused.clipboard == nil)
        #expect(!slot.isLive)
        refused.stop()
        // A reserved request whose view closed before it started gives its claim back.
        let early = try #require(slot.claim())
        let (closed, wiringC) = await controller(port: 9, pasteboard: pasteboard, slot: slot, defaults: defaults)
        closed.stop()
        closed.start(source(automatic: false, claim: early), window: nil)
        #expect(!slot.isLive && !slot.isTearingDown)
        for wiring in [wiringA, wiringB, wiringC] { await wiring.channel.close() }
    }

    @Test func requestsAreReservedInTheirOwnWindowBeforeAnySideEffect() throws {
        // The app's controllers and requests share one owner.
        #expect(SessionController().slot === LiveSessionSlot.shared)
        let slot = LiveSessionSlot()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let requesting = UIWindow(windowScene: scene), other = UIWindow(windowScene: scene)
        requesting.rootViewController = UIViewController()
        other.rootViewController = UIViewController()
        defer { requesting.windowScene = nil; other.windowScene = nil }
        // The presenter is the requesting window's own, never another one's.
        #expect(SessionPresenter.presenter(in: requesting) === requesting.rootViewController)
        #expect(SessionPresenter.presenter(in: other) === other.rootViewController)
        #expect(SessionPresenter.presenter(in: nil) == nil)
        guard case .reserved(let first) = RootView.reserveLiveSession(in: requesting, slot: slot) else {
            Issue.record("the first request must be reserved"); return
        }
        #expect(slot.holds(first))
        guard case .refused(let reason) = RootView.reserveLiveSession(in: other, slot: slot) else {
            Issue.record("a second request must be refused"); return
        }
        #expect(reason.contains("Another Mac session is open") && slot.holds(first))
        slot.finish(first)
        // No window to present in: refused before claiming anything.
        guard case .refused = RootView.reserveLiveSession(in: nil, slot: slot) else { Issue.record("expected a refusal"); return }
        #expect(!slot.isLive)
    }
}
