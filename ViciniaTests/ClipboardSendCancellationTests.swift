// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
@testable import Vicinia

@Suite("Clipboard outbound cancellation")
@MainActor
struct ClipboardSendCancellationTests {
    let pasteboard = FakePasteboard()
    let wire = FakeAccessoryWire()
    let session = SessionToken(profileID: UUID(), generation: 1)

    private func bridge(automatic: Bool = true,
                        deadline: @escaping @MainActor () -> ClipboardReadDeadline = { .init() },
                        encode: ClipboardBridge.OutboundEncoder? = nil) -> ClipboardBridge {
        let wire = self.wire
        if let encode {
            return ClipboardBridge(automaticSync: automatic, pasteboard: pasteboard,
                                   send: { await wire.send($0, $1) }, saveAutomaticSync: { _ in },
                                   readDeadline: deadline, encodeOutbound: encode)
        }
        return ClipboardBridge(automaticSync: automatic, pasteboard: pasteboard,
                               send: { await wire.send($0, $1) }, saveAutomaticSync: { _ in },
                               readDeadline: deadline)
    }

    private func grant(_ bridge: ClipboardBridge, _ operation: UInt64 = 1) {
        bridge.grant(FeatureAuthorization(session: session, operation: operation))
    }

    private func copy(_ text: String) { pasteboard.copy([[ClipboardFormats.text: Data(text.utf8)]]) }

    @Test func timeoutReleasesTheSendWithoutRetryingTheSameCopy() async throws {
        let clock = ManualClipboardDeadline()
        let deadline = DeadlineSequence(first: clock)
        let bridge = bridge(deadline: { deadline.next() })
        defer { bridge.end(); pasteboard.probe.release(); clock.expire() }
        grant(bridge)
        pasteboard.probe.hold()
        copy("late")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { pasteboard.probe.parkedLoads == 1 })
        clock.expire()
        try #require(await clipboardReached { !bridge.isSending })
        #expect(bridge.automaticReadPaused)
        #expect(bridge.notice?.message == "Automatic sending is paused: reading the clipboard timed out. Use Send Clipboard to Mac in Options, or turn Sync Automatically off and on to resume.")
        bridge.localPasteboardChanged()
        copy("while paused")
        bridge.localPasteboardChanged()
        #expect(pasteboard.reads == 1 && wire.texts.isEmpty)
        pasteboard.probe.release()
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await clipboardReached { wire.texts == ["while paused"] && !bridge.isSending })
        bridge.setAutomaticSync(false)
        bridge.setAutomaticSync(true)
        copy("next")
        bridge.localPasteboardChanged()
        #expect(await clipboardReached { wire.texts == ["while paused", "next"] && !bridge.isSending })
        #expect(pasteboard.reads == 2 && bridge.outstandingEchoCount == 2)
    }

    @Test func manualTimeoutDiscardsPartialContentWithoutPausingAutomaticReads() async throws {
        let clock = ManualClipboardDeadline()
        let deadline = DeadlineSequence(first: clock)
        let bridge = bridge(deadline: { deadline.next() })
        let stalled = ProviderProbe()
        defer { bridge.end(); stalled.release(); clock.expire() }
        grant(bridge)
        stalled.hold()
        let text = ClipboardFormats.text
        let first = pasteboard.probe.provider([(text, Data("first item".utf8))])
        let second = stalled.provider([(text, Data("late item".utf8))])
        bridge.sendManual([first, second])
        try #require(await clipboardReached { stalled.parkedLoads == 1 })
        #expect(pasteboard.probe.loads(text) == 1)
        clock.expire()
        try #require(await clipboardReached { !bridge.isSending })
        #expect(bridge.notice == .unreadableLocal)
        #expect(!bridge.automaticReadPaused && wire.texts.isEmpty)
        stalled.release()
        copy("next automatic copy")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { wire.texts.contains("next automatic copy") && !bridge.isSending })
        #expect(wire.texts == ["next automatic copy"])
        #expect(!bridge.automaticReadPaused)
    }

    @Test func aTimeoutAlreadyResolvedForAnAbandonedReadCannotPauseItsSuccessor() async throws {
        let clock = ManualClipboardDeadline()
        let deadline = DeadlineSequence(first: clock)
        let bridge = bridge(deadline: { deadline.next() })
        let provider = StalledTextProvider()
        defer { bridge.end(); pasteboard.probe.release(); clock.expire() }
        grant(bridge)
        pasteboard.automaticProviders = [provider]
        copy("old")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { provider.started.withLock { $0 } })

        clock.expire()
        // Progress cancellation follows continuation resumption. Keep this
        // actor turn until the successor owns the send, so the old timeout
        // has resolved below the bridge but cannot yet publish its notice.
        try #require(provider.waitForTimeoutResolution())
        bridge.setAutomaticSync(false)
        bridge.setAutomaticSync(true)
        pasteboard.automaticProviders = nil
        pasteboard.probe.hold()
        copy("new")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { pasteboard.probe.parkedLoads == 1 })
        #expect(bridge.isSending && !bridge.automaticReadPaused && bridge.notice == nil)
        pasteboard.probe.release()
        try #require(await clipboardReached { wire.texts.contains("new") && !bridge.isSending })
        #expect(wire.texts == ["new"] && !bridge.automaticReadPaused && bridge.notice == nil)
    }

    @Test func optingOutDuringLoadingAllowsManualRecoveryAndDoesNotReplay() async throws {
        let bridge = bridge()
        defer { bridge.end(); pasteboard.probe.release() }
        grant(bridge)
        pasteboard.probe.hold()
        copy("old")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { pasteboard.probe.parkedLoads == 1 })
        bridge.setAutomaticSync(false)
        #expect(!bridge.isSending)
        bridge.setAutomaticSync(true)
        bridge.localPasteboardChanged()
        #expect(pasteboard.reads == 1)
        pasteboard.probe.release()
        copy("new")
        bridge.sendManual(pasteboard.pasteControlProviders)
        #expect(await clipboardReached { wire.texts == ["new"] && !bridge.isSending })
        #expect(bridge.outstandingEchoCount == 1)
    }

    @Test(arguments: [true, false])
    func manualSendContinuesWithSyncOff(_ startOn: Bool) async throws {
        let bridge = bridge(automatic: startOn)
        defer { bridge.end(); pasteboard.probe.release() }
        grant(bridge)
        pasteboard.probe.hold()
        copy("manual")
        bridge.sendManual(pasteboard.pasteControlProviders)
        try #require(await clipboardReached { pasteboard.probe.parkedLoads == 1 })
        bridge.setAutomaticSync(false)
        #expect(bridge.isSending)
        pasteboard.probe.release()
        #expect(await clipboardReached { wire.texts == ["manual"] && !bridge.isSending })
        #expect(bridge.notice == .sentToMac && pasteboard.reads == 0)
    }

    @Test func optingOutDuringEncodingAbandonsThatCopyAcrossReenable() async throws {
        let gate = EncodingGate()
        let bridge = bridge(encode: { await gate.encode($0, $1, $2) })
        defer { bridge.end(); gate.open() }
        grant(bridge)
        copy("encoding")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { gate.started })
        bridge.setAutomaticSync(false)
        #expect(!bridge.isSending)
        bridge.setAutomaticSync(true)
        bridge.localPasteboardChanged()
        #expect(pasteboard.reads == 1)
        gate.open()
        try #require(await clipboardReached { gate.finished })
        // A distinct copy must be deliverable after the abandoned encoder returns.
        copy("eligible")
        bridge.localPasteboardChanged()
        #expect(await clipboardReached { wire.texts.contains("eligible") && !bridge.isSending })
        #expect(wire.texts == ["eligible"])
        #expect(bridge.messagesQueued == 2)
    }

    @Test func queuedAbandonedSendCannotTakeOwnershipOrCompleteTheNewSend() async throws {
        let bridge = bridge()
        defer { wire.release(); bridge.end() }
        wire.held = true
        grant(bridge)
        try #require(await clipboardReached { wire.waiting == 1 })
        copy("abandoned")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { bridge.messagesQueued == 2 })
        bridge.setAutomaticSync(false)
        #expect(!bridge.isSending)
        bridge.setAutomaticSync(true)
        copy("current")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { bridge.messagesQueued == 3 })
        wire.atNextClipboardWrite(.inside) {
            #expect(bridge.isSending)
            #expect(wire.texts == ["current"])
        }
        wire.release()
        try #require(await clipboardReached { wire.texts.contains("current") && !bridge.isSending })
        #expect(wire.texts == ["current"])
        bridge.handle(.remoteChanged)
        try #require(await clipboardReached { wire.requests == 1 })
        let echo = try #require(wire.sent.first { $0.first == 0x1F })
        bridge.handle(.content(echo))
        try #require(await clipboardReached { !bridge.hasRequestInFlight })
        #expect(pasteboard.writes == 0 && bridge.outstandingEchoCount == 0)
    }

    @Test func optingOutAfterHandoffKeepsAlreadySubmittedEchoMemory() async throws {
        let bridge = bridge()
        defer { wire.release(); bridge.end() }
        grant(bridge)
        try #require(await clipboardReached { wire.enables == 1 })
        wire.held = true
        copy("handed off")
        bridge.localPasteboardChanged()
        try #require(await clipboardReached { wire.waiting == 1 })
        bridge.setAutomaticSync(false)
        #expect(!bridge.isSending)
        wire.release()
        #expect(await clipboardReached { wire.texts == ["handed off"] && bridge.outstandingEchoCount == 1 })
    }
}

@MainActor
private final class DeadlineSequence {
    private var first: ManualClipboardDeadline?

    init(first: ManualClipboardDeadline) { self.first = first }

    func next() -> ClipboardReadDeadline {
        defer { first = nil }
        return first?.deadline() ?? .init()
    }
}

private final class StalledTextProvider: NSItemProvider {
    let started = Mutex(false)
    private let cancelled = DispatchSemaphore(value: 0)

    func waitForTimeoutResolution() -> Bool {
        cancelled.wait(timeout: .now() + .seconds(3)) == .success
    }

    override init() {
        super.init()
        registerDataRepresentation(forTypeIdentifier: ClipboardFormats.text, visibility: .all) { _ in nil }
    }

    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String,
                                         completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { [cancelled] in _ = cancelled.signal() }
        started.withLock { $0 = true }
        return progress
    }
}

private final class EncodingGate: Sendable {
    private let signals = Mutex((started: false, finished: false))
    private let gate = AsyncStream<Void>.makeStream()
    var started: Bool { signals.withLock { $0.started } }
    var finished: Bool { signals.withLock { $0.finished } }
    func open() { gate.continuation.finish() }

    func encode(_ items: [ClipboardItem], _ limits: ClipboardLimits, _ maxMessage: Int)
        async -> Result<ClipboardFormats.Outbound, ClipboardIssue> {
        let first = signals.withLock { signals in
            defer { signals.started = true }
            return !signals.started
        }
        if first {
            // Task cancellation would otherwise finish the stream immediately.
            await Task.detached { [self] in for await _ in gate.stream {} }.value
        }
        let result = ClipboardFormats.encodeOutbound(items, limits: limits, maxMessage: maxMessage)
        if first { signals.withLock { $0.finished = true } }
        return result
    }
}
