// Vicinia tests — ClipboardBridge policy with a fake local pasteboard and a
// fake accessory writer: permissions, freshness, echo, repeated copies,
// revocation, lock reset and host switch.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Vicinia

/// Item providers whose loads are counted per type; a type can fail to load,
/// and loads can be held (still loading) until released.
final class ProviderProbe: Sendable {
    private struct State {
        var loads: [String: Int] = [:]
        var failing: Set<String> = []
        var held = false
        var parked: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    func loads(_ type: String) -> Int { state.withLock { $0.loads[type, default: 0] } }
    var parkedLoads: Int { state.withLock { $0.parked.count } }
    func fail(_ types: Set<String>) { state.withLock { $0.failing = types } }
    func hold() { state.withLock { $0.held = true } }
    func release() {
        let parked = state.withLock { s in
            s.held = false
            defer { s.parked.removeAll() }
            return s.parked
        }
        for deliver in parked { deliver() }
    }

    /// One provider registering `entries` in this order (highest fidelity first).
    func provider(_ entries: [(String, Data)]) -> NSItemProvider {
        let provider = NSItemProvider()
        for (type, data) in entries {
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { [self] completion in
                let (failing, park) = self.state.withLock { s in
                    s.loads[type, default: 0] += 1
                    return (s.failing.contains(type), s.held)
                }
                let deliver: @Sendable () -> Void = {
                    if failing { completion(nil, CocoaError(.fileReadUnknown)) } else { completion(data, nil) }
                }
                if park { self.state.withLock { $0.parked.append(deliver) } } else { deliver() }
                return nil
            }
        }
        return provider
    }
}

/// A provider that cannot make file representations (its data loads normally).
final class NoFileProvider: NSItemProvider, @unchecked Sendable {
    private let attempts = Mutex(0)
    var fileAttempts: Int { attempts.withLock { $0 } }
    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                         completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        attempts.withLock { $0 += 1 }
        completionHandler(nil, CocoaError(.fileReadUnknown))
        return Progress(totalUnitCount: 0)
    }
}

/// The general pasteboard as the bridge sees it; another app copies with `copy`.
@MainActor final class FakePasteboard: LocalPasteboard {
    private(set) var items: [ClipboardItem] = []
    private(set) var changeCount = 0
    /// false: the system refuses programmatic reads (denied paste).
    var allowsRead = true
    var automaticProviders: [NSItemProvider]?
    private(set) var reads = 0
    private(set) var writes = 0
    let probe = ProviderProbe()

    /// As UIKit's detection: true when a shareable type is present, without reading it.
    var mayHaveShareableContent: Bool {
        items.contains { $0.keys.contains { ClipboardFormats.shareable.contains($0) || ClipboardFormats.localText.contains($0) } }
    }
    func itemProviders() -> [NSItemProvider] {
        reads += 1
        return allowsRead ? (automaticProviders ?? providers) : []
    }
    func write(_ items: [ClipboardItem]) { self.items = items; changeCount += 1; writes += 1 }
    func copy(_ items: [ClipboardItem]) { self.items = items; changeCount += 1 }
    func advanceChangeCount(by amount: Int) { changeCount += amount }

    /// What the system paste control would hand over for the current content.
    var pasteControlProviders: [NSItemProvider] { providers }
    private var providers: [NSItemProvider] {
        items.map { item in probe.provider(item.keys.sorted().map { ($0, item[$0]!) }) }
    }
}

/// The session's accessory writer as the bridge sees it; can hold writes in flight.
@MainActor final class FakeAccessoryWire {
    private(set) var sent: [[UInt8]] = []
    var outcome: AccessoryOutcome = .submitted
    var held = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func send(_ message: [UInt8], _ authorization: FeatureAuthorization) async -> AccessoryOutcome {
        if held { await withCheckedContinuation { parked.append($0) } }
        sent.append(message)
        if let observer, message.first == observer.type {
            self.observer = nil
            switch observer.moment {
            case .inside: observer.body()
            case .after: Task { @MainActor in observer.body() }
            }
        }
        return outcome
    }

    /// Where a later operation first meets the next 0x1f write's completion:
    /// `.inside` before the writer returns its outcome (a Mac event read first);
    /// `.after` as the first main-actor job once it has returned (jobs run in
    /// the order they were enqueued, so this is deterministic, not a delay).
    enum Moment: Sendable { case inside, after }
    private var observer: (type: UInt8, moment: Moment, body: @MainActor () -> Void)?
    func atNextClipboardWrite(_ moment: Moment, _ body: @escaping @MainActor () -> Void) { observer = (0x1F, moment, body) }
    /// The same, at the next 0x0b request.
    func atNextRequest(_ moment: Moment, _ body: @escaping @MainActor () -> Void) {
        observer = (ClipboardWire.request[0], moment, body)
    }
    func release() {
        held = false
        let resumed = parked
        parked.removeAll()
        for c in resumed { c.resume() }
    }
    var waiting: Int { parked.count }
    var requests: Int { sent.filter { $0 == ClipboardWire.request }.count }
    var enables: Int { sent.filter { $0 == ClipboardWire.autoPasteboardEnable }.count }
    /// Texts of the 0x1f messages sent, in order.
    var texts: [String] {
        sent.filter { $0.first == 0x1F }.compactMap { message in
            guard let items = try? ClipboardWire.decode(message),
                  let text = items.first?.flavors.first(where: { $0.type == ClipboardFormats.text }) else { return nil }
            return String(decoding: text.data, as: UTF8.self)
        }
    }
}

@Suite("Clipboard bridge policy", .serialized)
@MainActor
struct ClipboardBridgeTests {
    let pasteboard = FakePasteboard()
    let wire = FakeAccessoryWire()
    private let session = SessionToken(profileID: UUID(), generation: 900)

    private func grant(_ operation: UInt64) -> FeatureAuthorization { FeatureAuthorization(session: session, operation: operation) }

    private func bridge(automatic: Bool = true, saved: @escaping @MainActor (Bool) -> Void = { _ in },
                        allowed: @escaping @MainActor () -> Bool = { true }) -> ClipboardBridge {
        let wire = self.wire
        return ClipboardBridge(automaticSync: automatic, pasteboard: pasteboard,
                               send: { await wire.send($0, $1) }, saveAutomaticSync: saved, automaticReadAllowed: allowed)
    }

    /// Runs the main-actor jobs already enqueued (they run in order), without a delay.
    private func drain() async { for _ in 0..<3 { await Task { @MainActor in }.value } }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Lets queued main-actor work and background decoding run.
    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    private func text(_ s: String) -> [ClipboardItem] { [[ClipboardFormats.text: Data(s.utf8)]] }
    private func mac(_ s: String, extra: Bool = false) -> [UInt8] {
        var flavors = [ClipboardFixture.Flavor(type: ClipboardFormats.text, tags: [], data: Array(s.utf8))]
        if extra { flavors.append(.init(type: "com.apple.traditional-mac-plain-text", tags: [], data: Array(s.utf8))) }
        return ClipboardFixture.message(archive: ClipboardFixture.archive([flavors]))
    }

    @Test func aSessionNeverUploadsTheClipboardItStartedWith() async {
        pasteboard.copy(text("copied before connecting"))
        let bridge = bridge()
        bridge.grant(grant(1))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.enables == 1 })
        await settle()
        #expect(wire.texts.isEmpty && pasteboard.reads == 0)
    }

    @Test func localCopiesAreSentAndAnIdenticalRepeatedCopyIsSentAgain() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("same"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["same"] })
        pasteboard.copy(text("same"))                      // an intentional identical copy
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["same", "same"] })
        bridge.localPasteboardChanged()                    // no new change: nothing
        await settle()
        #expect(wire.texts.count == 2)
    }

    @Test func macCopiesAreAppliedAndTheBridgesOwnWriteIsNotSentBack() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("from the Mac")))
        #expect(await eventually { pasteboard.items == text("from the Mac") })
        bridge.localPasteboardChanged()                    // UIKit reports the bridge's own write
        await settle()
        #expect(wire.texts.isEmpty && pasteboard.writes == 1)
    }

    @Test func theMacsEchoOfOurOwnCopyIsNotApplied() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("mine"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["mine"] })
        bridge.handle(.remoteChanged)                       // the Mac reports the change we caused
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("mine", extra: true)))   // with a representation of its own
        #expect(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.writes == 0)
        // A later identical Mac copy is a real one and is applied.
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 2 })
        bridge.handle(.content(mac("mine", extra: true)))
        #expect(await eventually { pasteboard.writes == 1 })
    }

    @Test func manualCommandsWorkWithAutomaticSyncOff() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        pasteboard.copy(text("local"))
        bridge.localPasteboardChanged()
        bridge.handle(.remoteChanged)
        await settle()
        #expect(wire.texts.isEmpty && wire.requests == 0 && pasteboard.reads == 0)
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.texts == ["local"] && bridge.notice == .sentToMac })
        bridge.receiveManual()
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("remote")))
        #expect(await eventually { pasteboard.items == text("remote") && bridge.notice == .copiedFromMac })
    }

    @Test func deniedPasteStopsAutomaticReadsWithoutAnotherPrompt() async {
        pasteboard.allowsRead = false
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("secret"))
        bridge.localPasteboardChanged()
        #expect(bridge.automaticReadPaused && bridge.notice == .automaticSendPaused && pasteboard.reads == 1)
        pasteboard.copy(text("secret again"))
        bridge.localPasteboardChanged()
        bridge.grant(grant(2))                              // even after a re-grant
        await settle()
        #expect(pasteboard.reads == 1 && wire.texts.isEmpty)
        // The system paste control remains the explicit path.
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.texts == ["secret again"] })
    }

    @Test(arguments: ["empty", "unsupported", "malformed", "oversize", "bomb"])
    func invalidMacContentNeverReplacesTheLocalClipboard(_ kind: String) async {
        pasteboard.copy(text("keep me"))
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        bridge.receiveManual()
        #expect(await eventually { wire.requests == 1 })
        switch kind {
        case "empty": bridge.handle(.content(ClipboardFixture.message(archive: [])))
        case "unsupported":
            bridge.handle(.content(ClipboardFixture.message(archive: ClipboardFixture.archive([[
                .init(type: "public.file-url", tags: [], data: Array("file:///x".utf8))]]))))
        case "malformed": bridge.handle(.content([0x1F] + [UInt8](repeating: 0xAB, count: 40)))
        case "oversize": bridge.handle(.oversize(compressed: 9 << 20))
        default:
            bridge.handle(.content(ClipboardFixture.message(archive: [], compressed: ClipboardFixture.deflate([UInt8](repeating: 0, count: 1 << 20)), declared: 64)))
        }
        let expected: ClipboardBridge.Notice = switch kind {
        case "empty": .macEmpty
        case "unsupported": .unsupportedFromMac
        case "oversize": .tooLargeToReceive(bytes: 9 << 20, limit: ClipboardLimits.standard.inboundCompressed)
        default: .unreadableFromMac
        }
        #expect(await eventually { bridge.notice == expected })
        #expect(pasteboard.items == text("keep me") && pasteboard.writes == 0 && !bridge.hasRequestInFlight)
    }

    @Test(arguments: [0, 2], [false, true])
    func manualReceiveWritesTheMacClipboard(_ advance: Int, _ empty: Bool) async throws {
        if !empty { pasteboard.copy(text("local")) }
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        bridge.receiveManual()
        try #require(await eventually { wire.requests == 1 })
        pasteboard.advanceChangeCount(by: advance)
        bridge.handle(.content(mac("remote")))
        try #require(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.items == text("remote"))
        #expect(pasteboard.writes == 1)
        #expect(bridge.notice == .copiedFromMac)
        #expect(pasteboard.reads == 0 && wire.requests == 1)
    }

    @Test(arguments: [false, true])
    func onlyExplicitReceiveReplacesAnInterveningCopy(_ manual: Bool) async throws {
        let bridge = bridge()
        bridge.grant(grant(1))
        if manual { bridge.receiveManual() } else { bridge.handle(.remoteChanged) }
        try #require(await eventually { wire.requests == 1 })
        pasteboard.copy(text("newer here"))
        bridge.handle(.content(mac("older on the Mac")))
        try #require(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.items == text(manual ? "older on the Mac" : "newer here"))
        #expect(pasteboard.writes == (manual ? 1 : 0))
        #expect(pasteboard.reads == 0 && wire.requests == 1)
    }

    @Test func repeatedMacContentIsWrittenAgainOnlyAfterTheLocalCountChanges() async throws {
        let bridge = bridge()
        bridge.grant(grant(1))
        for request in 1...3 {
            bridge.receiveManual()
            try #require(await eventually { wire.requests == request })
            if request == 3 { pasteboard.copy(text("intervening")) }
            bridge.handle(.content(mac("same")))
            try #require(await eventually { !bridge.hasRequestInFlight })
            #expect(pasteboard.items == text("same"))
            #expect(pasteboard.writes == (request == 3 ? 2 : 1))
            #expect(bridge.notice == (request == 2 ? .alreadyHere : .copiedFromMac))
            bridge.localPasteboardChanged()
            #expect(pasteboard.reads == 0 && wire.texts.isEmpty && wire.requests == request)
        }
    }

    @Test func anAnswerOlderThanANewerMacCopyIsRequestedAgain() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.remoteChanged)                       // announced while the first is pending
        bridge.handle(.content(mac("first")))
        #expect(await eventually { wire.requests == 2 })
        #expect(pasteboard.writes == 0)
        bridge.handle(.content(mac("second")))
        #expect(await eventually { pasteboard.items == text("second") })
    }

    @Test func unsolicitedAndRevokedAnswersAreIgnored() async {
        let bridge = bridge()
        bridge.handle(.content(mac("before any grant")))
        bridge.grant(grant(1))
        bridge.handle(.content(mac("unsolicited")))
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.revoke(.background)
        bridge.handle(.content(mac("late")))
        await settle()
        #expect(pasteboard.writes == 0 && !bridge.hasRequestInFlight && !bridge.isAuthorized)
        // A command while revoked has no effect beyond the notice.
        bridge.receiveManual()
        bridge.sendManual(pasteboard.pasteControlProviders)
        await settle()
        #expect(wire.requests == 1 && bridge.notice == .unavailable)
    }

    @Test func aSendHeldAcrossARevocationIsNotRepeatedAndStaysAnExpectedEcho() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.held = true
        pasteboard.copy(text("held"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.waiting == 1 })    // handed to the writer: possibly delivered
        bridge.revoke(.background)
        wire.release()
        #expect(await eventually { wire.texts == ["held"] })
        // Background revocation keeps the memory epoch, so the submitted echo is still expected.
        #expect(await eventually { !bridge.isSending } && bridge.outstandingEchoCount == 1)
        bridge.grant(grant(2))
        await settle()
        // Not repeated on the new grant, and the enable is not sent twice.
        #expect(wire.texts == ["held"] && wire.enables == 1)
    }

    @Test func aCopyMadeInTheBackgroundIsSentOnReturnButNotAfterALock() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        bridge.revoke(.background)
        pasteboard.copy(text("while away"))
        bridge.localPasteboardChanged()
        #expect(wire.texts.isEmpty)
        bridge.grant(grant(2))
        #expect(await eventually { wire.texts == ["while away"] })
        bridge.revoke(.deviceLock)
        pasteboard.copy(text("while locked"))
        bridge.grant(grant(3))                              // full reset: a new baseline
        await settle()
        #expect(wire.texts == ["while away"])
    }

    @Test func aNewSessionForAnotherMacStartsWithNoSharedMemory() async {
        let first = bridge()
        first.grant(grant(1))
        first.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        first.handle(.content(mac("from Mac A")))
        #expect(await eventually { pasteboard.writes == 1 })
        first.end()
        first.handle(.remoteChanged)
        first.localPasteboardChanged()
        // Host B: nothing is uploaded at start, and Mac A's content is not "already applied".
        let second = bridge()
        second.grant(FeatureAuthorization(session: SessionToken(profileID: UUID(), generation: 901), operation: 9))
        await settle()
        #expect(wire.texts.isEmpty && wire.requests == 1)
        second.receiveManual()
        #expect(await eventually { wire.requests == 2 })
        second.handle(.content(mac("from Mac A")))
        #expect(await eventually { pasteboard.writes == 2 && second.notice == .copiedFromMac })
    }

    @Test func automaticSyncIsSavedAndStartsFromTheCurrentCopy() async {
        var saved: [Bool] = []
        pasteboard.copy(text("before enabling"))
        let bridge = bridge(automatic: false) { saved.append($0) }
        bridge.grant(grant(1))
        bridge.setAutomaticSync(true)
        bridge.localPasteboardChanged()
        await settle()
        #expect(saved == [true] && wire.texts.isEmpty)
        bridge.setAutomaticSync(false)
        #expect(saved == [true, false])
    }

    @Test func anImageTooLargeForTheSessionIsSentAsItsTextAndSaidSo() async {
        let bridge = ClipboardBridge(automaticSync: false, pasteboard: pasteboard, maxMessage: 64 << 10,
                                     send: { [wire] in await wire.send($0, $1) }, saveAutomaticSync: { _ in })
        bridge.grant(grant(1))
        pasteboard.copy([["public.png": ClipboardFixture.noisePNG(side: 200), ClipboardFormats.text: Data("caption".utf8)]])
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.texts == ["caption"] && bridge.notice == .sentWithoutImages })
    }

    @Test func tooLargeLocalContentIsAnExplicitLimitNotATruncation() async {
        let bridge = ClipboardBridge(automaticSync: false, pasteboard: pasteboard, maxMessage: 4 << 10,
                                     send: { [wire] in await wire.send($0, $1) }, saveAutomaticSync: { _ in })
        bridge.grant(grant(1))
        let noise = String((0..<(64 << 10)).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        pasteboard.copy(text(noise))
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually {
            if case .tooLargeToSend(_, 4 << 10) = bridge.notice { return true } else { return false }
        })
        #expect(wire.texts.isEmpty)
    }

    // MARK: Stale echoes and answers

    /// The flavors of each 0x1f sent, in order.
    private var sentItems: [[ClipboardWire.Item]] {
        wire.sent.filter { $0.first == 0x1F }.compactMap { try? ClipboardWire.decode($0) }
    }

    @Test func aDelayedEchoNeverOverwritesANewerCopyThatCouldNotBeSent() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        let unsupported: [ClipboardItem] = [["public.file-url": Data("file:///private/b".utf8)]]
        pasteboard.copy(unsupported)                                   // B: nothing shareable, never sent
        bridge.localPasteboardChanged()
        bridge.handle(.remoteChanged)                                  // the Mac's late notice of A
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { !bridge.hasRequestInFlight })
        await settle()
        #expect(pasteboard.items == unsupported && pasteboard.writes == 0)
        // Resolved, not remembered: an explicit Receive still takes the Mac clipboard.
        #expect(bridge.outstandingEchoCount == 0)
        bridge.receiveManual()
        #expect(await eventually { wire.requests == 2 })
        bridge.handle(.content(mac("A")))
        #expect(await eventually { pasteboard.items == text("A") && bridge.notice == .copiedFromMac })
    }

    @Test func aDelayedEchoNeverOverwritesANewerCopyTooLargeToSend() async {
        let bridge = ClipboardBridge(automaticSync: true, pasteboard: pasteboard, maxMessage: 4 << 10,
                                     send: { [wire] in await wire.send($0, $1) }, saveAutomaticSync: { _ in })
        bridge.grant(grant(1))
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        var seed: UInt32 = 3
        let noise = String((0..<(64 << 10)).map { _ -> Character in
            seed = seed &* 1_103_515_245 &+ 12_345
            return Character(UnicodeScalar(UInt8(33 + (seed >> 16) % 90)))
        })
        pasteboard.copy(text(noise))                                   // B: too large for the session
        bridge.localPasteboardChanged()
        #expect(await eventually { if case .tooLargeToSend = bridge.notice { true } else { false } })
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A")))
        #expect(await eventually { !bridge.hasRequestInFlight })
        await settle()
        #expect(pasteboard.items == text(noise) && pasteboard.writes == 0 && wire.texts == ["A"])
    }

    @Test func aDelayedEchoNeverOverwritesANewerCopyStillBeingRead() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        pasteboard.probe.hold()
        pasteboard.copy(text("B"))
        bridge.localPasteboardChanged()
        #expect(await eventually { pasteboard.probe.parkedLoads == 1 })   // B is still being read
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A")))
        #expect(await eventually { !bridge.hasRequestInFlight })
        await settle()
        #expect(pasteboard.items == text("B") && pasteboard.writes == 0)              // B still being read: kept
        pasteboard.probe.release()
        #expect(await eventually { wire.texts == ["A", "B"] })
    }

    @Test(arguments: [false, true])
    func anAnswerRequestedBeforeANewerLocalSendIsNotApplied(_ promote: Bool) async throws {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("B"))
        if promote { bridge.handle(.remoteChanged) } else { bridge.receiveManual() }
        try #require(await eventually { wire.requests == 1 })
        bridge.sendManual(pasteboard.pasteControlProviders)            // after the request, before its answer
        try #require(await eventually { wire.texts == ["B"] && !bridge.isSending })
        if promote { bridge.receiveManual() }                          // retains the work captured by the request
        bridge.handle(.content(mac("X: what the Mac had before B")))
        try #require(await eventually { !bridge.hasRequestInFlight })
        #expect(bridge.notice?.message == String(localized: "Another clipboard operation occurred while receiving. Your clipboard was kept."))
        #expect(pasteboard.items == text("B") && pasteboard.writes == 0)
        #expect(wire.requests == 1 && pasteboard.reads == 0)
    }

    @Test func aManualReceiveKeepsLocalContentWhileASendIsStillLoading() async throws {
        pasteboard.copy(text("sending"))
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        pasteboard.probe.hold()
        defer { pasteboard.probe.release() }
        bridge.sendManual(pasteboard.pasteControlProviders)
        try #require(await eventually { pasteboard.probe.parkedLoads == 1 })
        bridge.receiveManual()                                        // work already started before this request
        try #require(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("remote")))
        try #require(await eventually { !bridge.hasRequestInFlight })
        #expect(bridge.isSending && bridge.notice == .busy)
        #expect(pasteboard.items == text("sending") && pasteboard.writes == 0)
        #expect(wire.requests == 1 && pasteboard.reads == 0)
        pasteboard.probe.release()
        #expect(await eventually { wire.texts == ["sending"] && !bridge.isSending })
    }

    @Test func echoMemoryIsBoundedAndALaterIdenticalMacCopyIsApplied() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        for i in 0..<12 {
            pasteboard.copy(text("n\(i)"))
            bridge.localPasteboardChanged()
            #expect(await eventually { wire.texts.count == i + 1 })
        }
        #expect(bridge.outstandingEchoCount == ClipboardBridge.outstandingEchoLimit)
        // The Mac's own newer copy resolves every earlier send.
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("from the Mac")))
        #expect(await eventually { pasteboard.writes == 1 })
        #expect(bridge.outstandingEchoCount == 0)
        // Identical to one of the sends, but a real copy on the Mac: applied.
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 2 })
        bridge.handle(.content(mac("n11")))
        #expect(await eventually { pasteboard.items == text("n11") && pasteboard.writes == 2 })
    }

    // MARK: 0x15 monitoring activation

    @Test func monitoringIsTurnedOnAcrossARapidGrantRevokeGrant() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        bridge.revoke(.background)
        bridge.grant(grant(2))                                         // before the first enable could be sent
        #expect(await eventually { wire.enables == 1 })
        // Revoked with no grant after it: sent at the next grant.
        let other = ClipboardBridge(automaticSync: false, pasteboard: pasteboard, send: { [wire] in await wire.send($0, $1) },
                                    saveAutomaticSync: { _ in })
        other.grant(grant(3))
        other.revoke(.background)
        await settle()
        #expect(wire.enables == 1)
        other.grant(grant(4))
        #expect(await eventually { wire.enables == 2 })
        await settle()
        #expect(wire.enables == 2)
    }

    // MARK: One representation of each kind

    @Test func oneImageIsLoadedPerItemThePreferredCompressedOneInFidelityOrder() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        let tiff = ClipboardFixture.image(.tiff), jpeg = ClipboardFixture.image(.jpeg), png = ClipboardFixture.image(.png)
        let probe = ProviderProbe()
        bridge.sendManual([probe.provider([(UTType.tiff.identifier, tiff), (UTType.jpeg.identifier, jpeg), (UTType.png.identifier, png)])])
        #expect(await eventually { bridge.notice == .sentToMac })
        #expect(sentItems.last == [.init(flavors: [.init(type: UTType.jpeg.identifier, data: [UInt8](jpeg))])])
        #expect(probe.loads(UTType.jpeg.identifier) == 1 && probe.loads(UTType.tiff.identifier) == 0
                && probe.loads(UTType.png.identifier) == 0)
        // TIFF only when there is no compressed representation.
        let only = ProviderProbe()
        bridge.sendManual([only.provider([(UTType.tiff.identifier, tiff)])])
        #expect(await eventually { sentItems.count == 2 })
        #expect(sentItems.last == [.init(flavors: [.init(type: UTType.tiff.identifier, data: [UInt8](tiff))])])
        // HEIC first: its own bytes, never a conversion.
        let heic = ProviderProbe()
        bridge.sendManual([heic.provider([(UTType.heic.identifier, ClipboardFixture.heic), (UTType.png.identifier, png)])])
        #expect(await eventually { sentItems.count == 3 })
        #expect(sentItems.last == [.init(flavors: [.init(type: UTType.heic.identifier, data: [UInt8](ClipboardFixture.heic))])])
        #expect(heic.loads(UTType.png.identifier) == 0)
    }

    @Test func oneTextSpellingIsLoadedAndDistinctRichRepresentationsAreKept() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        let rtf = Data("{\\rtf1\\ansi bold}".utf8), html = Data("<b>bold</b>".utf8), plain = Data("bold".utf8)
        let link = Data("https://example.com/a?b=c".utf8)
        let probe = ProviderProbe()
        bridge.sendManual([probe.provider([(ClipboardFormats.text, plain), (UTType.plainText.identifier, plain),
                                           (UTType.text.identifier, plain), (ClipboardFormats.url, link),
                                           (ClipboardFormats.rtf, rtf), (ClipboardFormats.html, html)])])
        #expect(await eventually { bridge.notice == .sentToMac })
        #expect(probe.loads(ClipboardFormats.text) == 1 && probe.loads(UTType.plainText.identifier) == 0
                && probe.loads(UTType.text.identifier) == 0)
        #expect(probe.loads(ClipboardFormats.rtf) == 1 && probe.loads(ClipboardFormats.html) == 1 && probe.loads(ClipboardFormats.url) == 1)
        #expect(sentItems.last.map { $0.map { $0.flavors.map(\.type) } }
                == [[ClipboardFormats.html, ClipboardFormats.rtf, ClipboardFormats.url, ClipboardFormats.text]])
        #expect(sentItems.last?.first?.flavors.first { $0.type == ClipboardFormats.url }?.data == [UInt8](link))
        // Another spelling alone is the text.
        let other = ProviderProbe()
        bridge.sendManual([other.provider([(UTType.plainText.identifier, plain)])])
        #expect(await eventually { sentItems.count == 2 })
        #expect(sentItems.last == [.init(flavors: [.init(type: ClipboardFormats.text, data: [UInt8](plain))])])
    }

    @Test func richTextWithAnImageTooLargeToLoadIsSentWithoutTheImage() async {
        var limits = ClipboardLimits.standard
        limits.archive = 32 << 10
        let bridge = ClipboardBridge(automaticSync: false, pasteboard: pasteboard, limits: limits,
                                     send: { [wire] in await wire.send($0, $1) }, saveAutomaticSync: { _ in })
        bridge.grant(grant(1))
        let big = ClipboardFixture.noisePNG(side: 200), rtf = Data("{\\rtf1\\ansi caption}".utf8)
        #expect(big.count > limits.archive)
        bridge.sendManual([ProviderProbe().provider([(UTType.png.identifier, big), (ClipboardFormats.rtf, rtf),
                                                     (ClipboardFormats.text, Data("caption".utf8))])])
        #expect(await eventually { bridge.notice == .sentWithoutImages })
        #expect(sentItems.last.map { $0.map { $0.flavors.map(\.type) } } == [[ClipboardFormats.rtf, ClipboardFormats.text]])
        // The image alone: an explicit size limit, nothing sent.
        bridge.sendManual([ProviderProbe().provider([(UTType.png.identifier, big)])])
        #expect(await eventually { bridge.notice == .tooLargeToSend(bytes: big.count, limit: HPSSSession.accessoryBudget) })
        #expect(sentItems.count == 1)
    }

    // MARK: Failures, denial and unsupported types

    @Test func aRepresentationThatFailsToLoadIsReportedNotTakenForAnEmptyClipboard() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        let probe = ProviderProbe()
        probe.fail([ClipboardFormats.text])
        bridge.sendManual([probe.provider([(ClipboardFormats.text, Data("x".utf8))])])
        #expect(await eventually { bridge.notice == .unreadableLocal })
        #expect(sentItems.isEmpty && !bridge.automaticReadPaused)
        // One failed representation among others: what loaded is sent.
        let partial = ProviderProbe()
        partial.fail([ClipboardFormats.html])
        bridge.sendManual([partial.provider([(ClipboardFormats.html, Data("<b>x</b>".utf8)), (ClipboardFormats.text, Data("x".utf8))])])
        #expect(await eventually { bridge.notice == .sentToMac })
        #expect(sentItems.last == [.init(flavors: [.init(type: ClipboardFormats.text, data: Array("x".utf8))])])
    }

    @Test func anAutomaticReadThatFailsPausesAutomaticSendingWithoutAnotherPrompt() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.probe.fail([ClipboardFormats.text])
        pasteboard.copy(text("refused"))
        bridge.localPasteboardChanged()
        #expect(await eventually { bridge.automaticReadPaused && bridge.notice == .automaticSendPaused })
        #expect(pasteboard.reads == 1)
        pasteboard.copy(text("again"))
        bridge.localPasteboardChanged()
        bridge.grant(grant(2))
        await settle()
        #expect(pasteboard.reads == 1 && wire.texts.isEmpty)
        // The system paste control remains the explicit path.
        pasteboard.probe.fail([])
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.texts == ["again"] })
    }

    @Test func unsupportedLocalContentIsNeverReadAutomaticallyAndIsExplicitWhenPasted() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy([["com.adobe.pdf": Data("%PDF-1.7".utf8)]])
        bridge.localPasteboardChanged()
        await settle()
        #expect(pasteboard.reads == 0 && sentItems.isEmpty && bridge.notice == nil)
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { bridge.notice == .unsupportedToSend })
        #expect(sentItems.isEmpty)
    }

    @Test func itemCountsBeyondTheLimitAreReportedAsCounts() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        let limit = ClipboardLimits.standard.items
        bridge.sendManual((0...limit).map { _ in ProviderProbe().provider([(ClipboardFormats.text, Data("x".utf8))]) })
        #expect(await eventually { bridge.notice == .tooManyItemsToSend(limit: limit) })
        #expect(bridge.notice?.message.contains("\(limit) items") == true && sentItems.isEmpty)
        bridge.receiveManual()
        #expect(await eventually { wire.requests == 1 })
        let one = [ClipboardFixture.Flavor(type: ClipboardFormats.text, tags: [], data: Array("x".utf8))]
        bridge.handle(.content(ClipboardFixture.message(archive: ClipboardFixture.archive(Array(repeating: one, count: limit + 1)))))
        #expect(await eventually { bridge.notice == .tooManyItemsFromMac(limit: limit) })
        #expect(pasteboard.writes == 0)
    }

    @Test func anImageWhoseFileCannotBeMadeIsReadAsDataUnderTheSameBounds() async throws {
        let png = ClipboardFixture.image(.png), type = UTType.png.identifier
        let provider = NoFileProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        #expect(try await LocalClipboardReader.image(of: provider, type: type, budget: 1 << 20, limits: .standard) == .loaded(png))
        #expect(provider.fileAttempts == 1)                              // the file path was tried first and failed
        #expect(try await LocalClipboardReader.image(of: provider, type: type, budget: png.count - 1, limits: .standard) == .tooLarge(png.count))
        var tight = ClipboardLimits.standard
        tight.imagePixels = 1
        #expect(try await LocalClipboardReader.image(of: provider, type: type, budget: 1 << 20, limits: tight) == .invalid)
    }

    // MARK: Send completion ordering and revocation
    //
    // Interleavings are forced with `FakeAccessoryWire.atNextClipboardWrite`
    // and held writes, never with delays: `eventually` only waits for an
    // outcome that is already determined.

    nonisolated static let notSubmitted: [AccessoryOutcome] = [.busy, .tooLarge(limit: 4), .unavailable, .cancelled, .failed]

    /// The Mac announces a copy just as our send completes (before or after the
    /// writer returns): the request follows the send in wire order, so its answer
    /// reflects the send, and a different Mac copy is applied, not dropped.
    @Test(arguments: [FakeAccessoryWire.Moment.inside, .after])
    func aMacCopyAnnouncedAsOurSendCompletesIsApplied(_ moment: FakeAccessoryWire.Moment) async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.atNextClipboardWrite(moment) { bridge.handle(.remoteChanged) }
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.requests == 1 })
        #expect(wire.texts == ["A"] && wire.sent.last == ClipboardWire.request)       // the request after the send
        bridge.handle(.content(mac("B, copied on the Mac after A")))
        #expect(await eventually { pasteboard.items == text("B, copied on the Mac after A") })
        #expect(pasteboard.writes == 1 && bridge.outstandingEchoCount == 0)
    }

    /// The same announcement, but the answer is the Mac's echo of our copy: not
    /// applied, and resolved, so a later identical Mac copy is applied.
    @Test(arguments: [FakeAccessoryWire.Moment.inside, .after])
    func anEchoAnnouncedAsOurSendCompletesIsSuppressedAndResolved(_ moment: FakeAccessoryWire.Moment) async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.atNextClipboardWrite(moment) { bridge.handle(.remoteChanged) }
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.writes == 0 && bridge.outstandingEchoCount == 0)
        bridge.handle(.remoteChanged)                                   // a real, identical Mac copy
        #expect(await eventually { wire.requests == 2 })
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { pasteboard.writes == 1 })
    }

    /// The delayed echo of our copy answers a request the Mac has since
    /// overtaken with a newer copy: the echo is never applied, the newer copy is.
    @Test func aNewerMacCopyWinsOverTheDelayedEchoOfOurOwn() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        bridge.handle(.remoteChanged)                                   // the Mac applied A
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.remoteChanged)                                   // then copied B
        bridge.handle(.content(mac("A", extra: true)))                  // the answer: A, older than B
        #expect(await eventually { wire.requests == 2 })
        #expect(pasteboard.writes == 0)
        bridge.handle(.content(mac("B")))
        #expect(await eventually { pasteboard.items == text("B") && pasteboard.writes == 1 })
        #expect(bridge.outstandingEchoCount == 0)
    }

    /// Submitted, then the scene went to the background before the outcome
    /// arrived: no notice, still an expected echo (same memory), and the Mac's
    /// late echo after the return is not applied.
    @Test func aSendSubmittedAcrossABackgroundRevocationStaysAnExpectedEcho() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.held = true
        pasteboard.copy(text("A"))
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.waiting == 1 })                 // being written: possibly delivered
        bridge.revoke(.background)
        wire.release()
        #expect(await eventually { wire.texts == ["A"] && !bridge.isSending })
        #expect(bridge.outstandingEchoCount == 1 && bridge.notice == nil)
        bridge.grant(grant(2))
        bridge.handle(.remoteChanged)                                   // the Mac's late notice of A
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { !bridge.hasRequestInFlight })
        await settle()
        #expect(pasteboard.writes == 0 && pasteboard.items == text("A") && bridge.outstandingEchoCount == 0)
    }

    /// A newer copy made in the background after a submitted send (one that
    /// cannot be sent, or one sent on the return): the late echo of the earlier
    /// send never overwrites it.
    @Test(arguments: [false, true])
    func theLateEchoOfASendSubmittedBeforeTheBackgroundNeverOverwritesANewerCopy(_ newerIsSendable: Bool) async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.held = true
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.waiting == 1 })
        bridge.revoke(.background)
        wire.release()
        #expect(await eventually { wire.texts == ["A"] && !bridge.isSending })
        let newer: [ClipboardItem] = newerIsSendable ? text("B") : [["public.file-url": Data("file:///private/b".utf8)]]
        pasteboard.copy(newer)                                          // B, while in the background
        bridge.grant(grant(2))
        #expect(await eventually { wire.texts == (newerIsSendable ? ["A", "B"] : ["A"]) && !bridge.isSending })
        bridge.handle(.remoteChanged)
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A", extra: true)))                  // the Mac's late echo of A
        #expect(await eventually { !bridge.hasRequestInFlight })
        await settle()
        #expect(pasteboard.items == newer && pasteboard.writes == 0)
    }

    /// A memory reset (lock, end) while a send is being written: its outcome
    /// belongs to the earlier memory and is neither recorded nor reported.
    @Test(arguments: ["lock", "background then lock", "end"])
    func aSendCompletingAfterAMemoryResetIsNotRecorded(_ path: String) async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.held = true
        pasteboard.copy(text("A"))
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.waiting == 1 })
        switch path {
        case "lock": bridge.revoke(.deviceLock)
        case "background then lock": bridge.revoke(.background); bridge.revoke(.deviceLock)
        default: bridge.end()
        }
        wire.release()
        #expect(await eventually { wire.texts == ["A"] && !bridge.isSending })
        #expect(bridge.outstandingEchoCount == 0 && bridge.notice == nil)
    }

    /// Recorded across a background revocation, then forgotten at the lock.
    @Test func aLockAfterTheOutcomeForgetsTheExpectedEcho() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.held = true
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.waiting == 1 })
        bridge.revoke(.background)
        #expect(!bridge.isSending)
        wire.release()
        #expect(await eventually { bridge.outstandingEchoCount == 1 })
        bridge.revoke(.deviceLock)
        #expect(bridge.outstandingEchoCount == 0)
    }

    /// Not submitted: reported, not an expected echo, and the send is over; the
    /// Mac's identical clipboard is then copied, not taken for an echo.
    @Test(arguments: notSubmitted)
    func aSendThatWasNotSubmittedIsNotAnExpectedEcho(_ outcome: AccessoryOutcome) async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.outcome = outcome
        pasteboard.copy(text("A"))
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { wire.texts == ["A"] && !bridge.isSending })
        let expected: ClipboardBridge.Notice? = switch outcome {
        case .busy: .busy
        case .tooLarge(let limit): .tooLargeToSend(bytes: wire.sent.last?.count ?? 0, limit: limit)
        case .unavailable: .unavailable
        default: nil
        }
        #expect(bridge.notice == expected && bridge.outstandingEchoCount == 0)
        wire.outcome = .submitted
        bridge.receiveManual()
        #expect(await eventually { wire.requests == 1 })
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { bridge.notice == .copiedFromMac })
        #expect(pasteboard.writes == 1)
    }

    /// Back-to-back Sends: refused while the first is still being written,
    /// accepted from the moment it has completed, never a spurious "busy".
    @Test func aManualSendRightAfterTheLastOneCompletesIsAccepted() async {
        let bridge = bridge(automatic: false)
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        let seen = NoticeLog()
        pasteboard.copy(text("A"))
        wire.atNextClipboardWrite(.inside) {
            bridge.sendManual([ProviderProbe().provider([(ClipboardFormats.text, Data("early".utf8))])])
            seen.notices.append(bridge.notice)
        }
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await eventually { bridge.notice == .sentToMac })
        #expect(seen.notices == [.busy] && wire.texts == ["A"])
        wire.atNextClipboardWrite(.after) {
            seen.sending.append(bridge.isSending)
            bridge.sendManual([ProviderProbe().provider([(ClipboardFormats.text, Data("C".utf8))])])
            seen.notices.append(bridge.notice)
        }
        bridge.sendManual([ProviderProbe().provider([(ClipboardFormats.text, Data("B".utf8))])])
        #expect(await eventually { wire.texts == ["A", "B", "C"] })
        #expect(seen.sending == [false] && seen.notices == [.busy, .sentToMac])
        #expect(await eventually { !bridge.isSending } && bridge.outstandingEchoCount == 3)
    }

    /// Whatever the outcome, the send is over in the step that learns it.
    @Test(arguments: [AccessoryOutcome.submitted] + notSubmitted)
    func noSendStaysInProgressOnceItsOutcomeIsKnown(_ outcome: AccessoryOutcome) async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.outcome = outcome
        let seen = NoticeLog()
        wire.atNextClipboardWrite(.after) { seen.sending.append(bridge.isSending) }
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { seen.sending.count == 1 })
        #expect(seen.sending == [false])
    }

    /// Queued behind another write, then revoked before its turn: never sent,
    /// and the send is over.
    @Test func aSendCancelledInTheQueueEndsTheSend() async {
        let bridge = bridge()
        wire.held = true
        bridge.grant(grant(1))                                          // the 0x15 enable is held
        #expect(await eventually { wire.waiting == 1 })
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { bridge.messagesQueued == 2 })        // read, encoded, queued behind the enable
        #expect(bridge.isSending)
        bridge.revoke(.background)
        wire.release()
        #expect(await eventually { !bridge.isSending })
        #expect(wire.texts.isEmpty && bridge.outstandingEchoCount == 0)
    }

    // MARK: Answers before request dispatch
    //
    // Answers carry no request identity. Interleavings are forced with held
    // writes and `atNextClipboardWrite`/`atNextRequest`, never with delays.

    /// Request #1 is submitted, then abandoned; A is copied and its write is
    /// held; #2 is queued behind it. Returns once #2 is queued, not dispatched.
    private func abandonARequestThenQueueAnotherBehindAHeldSend(_ abandon: String) async -> ClipboardBridge {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        bridge.handle(.remoteChanged)                                   // #1: the Mac has X
        #expect(await eventually { wire.requests == 1 })
        wire.held = true
        switch abandon {
        case "background":
            bridge.revoke(.background)                                  // #1 abandoned; its answer still to come
            pasteboard.copy(text("A"))
            bridge.grant(grant(2))                                      // A, copied in the background, sent on the return
        default:
            bridge.setAutomaticSync(false)                              // #1 abandoned
            bridge.setAutomaticSync(true)
            pasteboard.copy(text("A"))
            bridge.localPasteboardChanged()
        }
        #expect(await eventually { wire.waiting == 1 })                 // A is being written
        bridge.handle(.remoteChanged)                                   // #2, queued behind A: the Mac now has A
        #expect(bridge.hasRequestInFlight && wire.requests == 1)
        return bridge
    }

    /// #2's own answer (the Mac's echo of A) after #2 is dispatched: taken by
    /// #2, resolving A; A is never overwritten.
    private func answerTheQueuedRequest(_ bridge: ClipboardBridge, requests: Int = 2) async {
        #expect(await eventually { wire.requests == requests && !bridge.isSending })
        #expect(bridge.hasRequestInFlight)                              // #2 still waits for its own answer
        bridge.handle(.content(mac("A", extra: true)))
        #expect(await eventually { !bridge.hasRequestInFlight })
        #expect(pasteboard.items == text("A") && pasteboard.writes == 0 && bridge.outstandingEchoCount == 0)
    }

    /// The abandoned request's answer (X, older than A) arrives before #2 is
    /// dispatched: while A is written, as A completes, or after A completes and
    /// before #2 leaves the queue. It is not #2's answer and is ignored.
    @Test(arguments: ["background", "automatic sync off"], ["while A is written", "as A completes", "after A completes"])
    func aStaleAnswerBeforeTheNewRequestIsDispatchedIsIgnored(_ abandon: String, _ moment: String) async {
        let bridge = await abandonARequestThenQueueAnotherBehindAHeldSend(abandon)
        let stale: @MainActor () -> Void = { bridge.handle(.content(mac("X: the Mac before A"))) }
        switch moment {
        case "while A is written": stale()
        case "as A completes": wire.atNextClipboardWrite(.inside, stale)
        default: wire.atNextClipboardWrite(.after, stale)
        }
        wire.release()
        await answerTheQueuedRequest(bridge)
    }

    /// The same for a stale oversize notice: neither reported nor taken as #2's answer.
    @Test(arguments: ["while A is written", "as A completes", "after A completes"])
    func aStaleOversizeNoticeBeforeTheNewRequestIsDispatchedIsIgnored(_ moment: String) async {
        let bridge = await abandonARequestThenQueueAnotherBehindAHeldSend("background")
        let seen = NoticeLog()
        let stale: @MainActor () -> Void = {
            bridge.handle(.oversize(compressed: 9 << 20))
            seen.notices.append(bridge.notice)
        }
        switch moment {
        case "while A is written": stale()
        case "as A completes": wire.atNextClipboardWrite(.inside, stale)
        default: wire.atNextClipboardWrite(.after, stale)
        }
        wire.release()
        #expect(await eventually { seen.notices.count == 1 })
        #expect(seen.notices == [nil])
        await answerTheQueuedRequest(bridge)
        #expect(bridge.notice == nil)
    }

    /// A request's own answer can be read before its outcome reaches the bridge:
    /// from dispatch on, it is taken.
    @Test func anAnswerReadBeforeTheRequestsOutcomeIsTaken() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        wire.atNextRequest(.inside) { bridge.handle(.content(mac("B, from the Mac"))) }
        bridge.handle(.remoteChanged)
        #expect(await eventually { pasteboard.items == text("B, from the Mac") })
        #expect(pasteboard.writes == 1 && !bridge.hasRequestInFlight)
    }

    /// A request that was not submitted ends its fetch in the step that learns
    /// it: a late answer or oversize notice read right after is not taken for it.
    /// The request waits behind the held enable, so its outcome is awaited
    /// before it is known: the late events run before that awaiter resumes.
    @Test(arguments: notSubmitted)
    func aRequestThatWasNotSubmittedTakesNoAnswer(_ outcome: AccessoryOutcome) async {
        let bridge = bridge(automatic: false)
        wire.held = true
        bridge.grant(grant(1))                                          // the 0x15 enable is held
        #expect(await eventually { wire.waiting == 1 })
        let seen = NoticeLog()
        wire.atNextRequest(.inside) {
            wire.outcome = outcome                                      // this request's outcome only
            Task { @MainActor in                                        // the first job once it is returned
                bridge.handle(.content(mac("X")))
                bridge.handle(.oversize(compressed: 9 << 20))
                seen.notices.append(bridge.notice)
            }
        }
        bridge.receiveManual()
        wire.release()
        #expect(await eventually { seen.notices.count == 1 })
        let expected: ClipboardBridge.Notice = outcome == .busy ? .busy : .unavailable
        #expect(seen.notices == [expected] && !bridge.hasRequestInFlight)
        #expect(pasteboard.writes == 0 && bridge.notice == expected)
    }

    // MARK: Abandoned queued requests

    /// The first fetch remains queued behind the monitoring write when it
    /// is abandoned (Sync off, then on, same
    /// grant); A and then #2 queue behind it. #1's request is cancelled at its
    /// turn and never sent, so no answer to it can exist: the Mac receives the
    /// enable, A and #2, in that order. An unsolicited answer before #2 leaves
    /// is still ignored, #1's cancellation is silent, and #2 (automatic or a
    /// manual Receive) takes its own answer.
    @Test(arguments: ["automatic", "manual"], [FakeAccessoryWire.Moment.inside, .after])
    func anAbandonedQueuedRequestIsNeverSentAndTheNewerFetchTakesItsOwnAnswer(_ newer: String,
                                                                            _ moment: FakeAccessoryWire.Moment) async {
        let bridge = bridge()
        wire.held = true
        bridge.grant(grant(1))                                          // the 0x15 enable is held
        #expect(await eventually { wire.waiting == 1 })
        bridge.handle(.remoteChanged)                                   // #1, queued behind the enable
        bridge.setAutomaticSync(false)                                  // #1 abandoned in the queue, same grant
        bridge.setAutomaticSync(true)
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { bridge.messagesQueued == 3 })        // A, queued behind #1
        if newer == "manual" { bridge.receiveManual() } else { bridge.handle(.remoteChanged) }   // #2, behind A
        #expect(bridge.hasRequestInFlight && bridge.messagesQueued == 4)
        let seen = NoticeLog()
        wire.atNextClipboardWrite(moment) {                             // as A is written, or right after: before #2 leaves
            bridge.handle(.content(mac("X: unsolicited, older than A")))
            bridge.handle(.oversize(compressed: 9 << 20))
            seen.notices.append(bridge.notice)
        }
        wire.release()
        #expect(await eventually { wire.requests == 1 && !bridge.isSending })
        #expect(wire.sent.map { $0[0] } == [0x15, 0x1F, 0x0B])          // wire order: #1 never left
        #expect(seen.notices == [nil] && bridge.notice == nil)          // silent cancellation, nothing taken early
        await answerTheQueuedRequest(bridge, requests: 1)
        #expect(bridge.notice == (newer == "manual" ? .alreadyHere : nil))
        #expect(wire.sent.map { $0[0] } == [0x15, 0x1F, 0x0B])
    }

    /// A request queued behind another write and revoked before its turn
    /// (background, lock) is cancelled, never sent, silently. After the new
    /// grant, a new request leaves after it and takes its own answer.
    @Test(arguments: [RevocationReason.background, .deviceLock])
    func aQueuedRequestRevokedBeforeItsTurnIsNeverSent(_ reason: RevocationReason) async {
        let bridge = bridge(automatic: false)
        wire.held = true
        bridge.grant(grant(1))                                          // the 0x15 enable is held
        #expect(await eventually { wire.waiting == 1 })
        bridge.receiveManual()                                          // #1, queued behind the enable
        bridge.revoke(reason)
        wire.release()
        bridge.grant(grant(2))
        bridge.receiveManual()                                          // #2, queued behind #1
        #expect(await eventually { wire.requests == 1 })                // #2 left: #1's turn is over
        #expect(wire.sent.map { $0[0] } == [0x15, 0x0B] && bridge.messagesQueued == 3 && bridge.notice == nil)
        bridge.handle(.content(mac("from the Mac")))
        #expect(await eventually { bridge.notice == .copiedFromMac })
        #expect(pasteboard.items == text("from the Mac") && wire.requests == 1)
    }

    // MARK: Pasteboard baseline requires authorization

    /// Sync Automatically turned on (or off and on) while unauthorized: before
    /// the first grant, after a device lock, or in the background. Nothing
    /// copied before the next grant is read or uploaded, by the grant itself,
    /// its deferred read or a later check; a copy made after it is sent.
    @Test(arguments: ["before the first grant", "after a lock", "in the background"])
    func syncTurnedOnWhileUnauthorizedNeverUploadsEarlierCopies(_ when: String) async {
        let bridge = bridge(automatic: when == "before the first grant" ? false : true)
        var next: UInt64 = 1
        if when != "before the first grant" {
            bridge.grant(grant(next)); next += 1
            #expect(await eventually { wire.enables == 1 })
            bridge.revoke(when == "after a lock" ? .deviceLock : .background)
        }
        pasteboard.copy(text("copied while unauthorized"))
        bridge.localPasteboardChanged()                                 // unauthorized: nothing
        bridge.setAutomaticSync(true)
        bridge.setAutomaticSync(false)
        bridge.setAutomaticSync(true)                                   // toggled while unauthorized
        pasteboard.copy(text("copied after the toggle, before the grant"))
        bridge.localPasteboardChanged()
        bridge.grant(grant(next))                                       // the baseline
        bridge.localPasteboardChanged()                                 // as a notification or check would
        await drain()                                                   // the grant's deferred read, if any
        #expect(await eventually { wire.enables == 1 })
        #expect(pasteboard.reads == 0 && wire.texts.isEmpty)
        pasteboard.copy(text("after the grant"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["after the grant"] })
        #expect(pasteboard.reads == 1)
    }

    /// While authorized, turning Sync Automatically off and on again starts
    /// from the current copy: what was copied while it was off is not sent; a
    /// later copy is.
    @Test func turningSyncBackOnWhileAuthorizedStartsFromTheCurrentCopy() async {
        let bridge = bridge()
        bridge.grant(grant(1))
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        bridge.setAutomaticSync(false)
        pasteboard.copy(text("B, while off"))
        bridge.localPasteboardChanged()
        bridge.setAutomaticSync(true)                                   // the new baseline
        bridge.localPasteboardChanged()
        await drain()
        #expect(wire.texts == ["A"] && pasteboard.reads == 1)
        pasteboard.copy(text("C"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A", "C"] })
        #expect(pasteboard.reads == 2)
    }

    /// A session that never got its grant (and was ended), then another
    /// session for another Mac: no toggle, baseline or copy carries over.
    @Test func noToggleOrCopyCarriesIntoAnotherSessionOrMac() async {
        let first = bridge(automatic: false)
        first.setAutomaticSync(true)                                    // during the first attempt, never granted
        pasteboard.copy(text("during the first attempt"))
        first.end()
        first.setAutomaticSync(false)
        first.setAutomaticSync(true)                                    // after its end: no effect
        first.localPasteboardChanged()
        let second = bridge()                                           // another Mac
        pasteboard.copy(text("between the sessions"))
        second.grant(FeatureAuthorization(session: SessionToken(profileID: UUID(), generation: 902), operation: 1))
        second.localPasteboardChanged()
        await drain()
        #expect(await eventually { wire.enables == 1 })                 // the second session's enable only
        #expect(pasteboard.reads == 0 && wire.texts.isEmpty)
        pasteboard.copy(text("in the second session"))
        second.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["in the second session"] })
        #expect(pasteboard.reads == 1)
    }

    // MARK: Automatic reads require scene eligibility

    /// While the session disallows automatic reads (scene inactive), no path
    /// reads: a notification or check, a re-grant's deferred read, or the
    /// check deferred behind a send in flight. The change stays unobserved and
    /// is read once when reads are allowed again.
    @Test func noAutomaticReadStartsWhileTheSessionDisallowsIt() async {
        let scene = SceneGate()
        let bridge = bridge(allowed: { scene.active })
        bridge.grant(grant(1))
        #expect(await eventually { wire.enables == 1 })
        scene.active = false                                            // Control Center, the paste prompt
        pasteboard.copy(text("A"))
        bridge.localPasteboardChanged()
        bridge.revoke(.background)
        bridge.grant(grant(2))                                          // a re-grant's deferred read
        await drain()
        #expect(pasteboard.reads == 0 && wire.texts.isEmpty)
        scene.active = true
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A"] })
        #expect(pasteboard.reads == 1)

        wire.held = true
        pasteboard.copy(text("B"))
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.waiting == 1 })                 // B is being written
        pasteboard.copy(text("C"))
        bridge.localPasteboardChanged()                                 // deferred behind B's send
        scene.active = false
        wire.release()
        #expect(await eventually { !bridge.isSending })
        await drain()
        #expect(pasteboard.reads == 2 && wire.texts == ["A", "B"])
        scene.active = true
        bridge.localPasteboardChanged()
        #expect(await eventually { wire.texts == ["A", "B", "C"] })
        #expect(pasteboard.reads == 3)
    }
}

/// Main-actor observations made inside a forced interleaving.
@MainActor final class NoticeLog {
    var notices: [ClipboardBridge.Notice?] = []
    var sending: [Bool] = []
}

/// The session's permission for automatic reads, as a test sets it.
@MainActor final class SceneGate {
    var active = true
}
