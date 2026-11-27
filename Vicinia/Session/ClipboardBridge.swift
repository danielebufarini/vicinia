// Vicinia — shared clipboard between this device and the current Mac,
// over the native Screen Sharing pasteboard messages of `ClipboardWire`.
// SPDX-License-Identifier: MIT
//
// Ownership: one bridge per live session, registered with its
// `SessionLifetime`; every effect needs the current `FeatureAuthorization`
// and is re-checked after each suspension, before the network write and
// before the pasteboard write. State is serial on the main actor.
//
// Clipboard policy:
// - Automatic sync is opt-in. Manual Send and Receive always work.
// - Nothing is sent automatically when a session starts, or after a device
//   lock: the first observed change count is the baseline.
// - Explicit sending uses the system paste control. Automatic sending reads
//   the pasteboard programmatically on the main actor and may prompt for
//   access. Denial, unreadable content or timeout can pause automatic reads.
//   The paste control remains available. Re-enabling automatic sync resumes
//   reads from the current change count. The provider deadline applies after
//   the UIKit getter returns. Programmatic reads run outside the synchronous
//   scene-activation callbacks and at most once per local change.
// - Local triggers are a change notification, a return to active, and a
//   metadata check on the session timer. The check runs at most once a second
//   while the scene is active, authorized and automatic sync is enabled.
//   A copy from another app can advance the count without a notification.
//   Comparing the count lets the bridge detect that copy without reading
//   an unchanged clipboard. An advance triggers at most one content read
//   across all three triggers.
// - Automatic receive protects newer local copies. Explicit receive may
//   replace a copy made while waiting. Both keep local content if a send
//   intervened or is active, and request again if the Mac announced a newer
//   copy. Messages travel in one ordered stream, so an answer can reflect
//   only this bridge's sends that precede its request. The answer resolves
//   those outstanding echoes (bounded). An echo is never applied automatically, whatever
//   was copied since. A repeated identical copy is a new change and is sent
//   again; a resolved echo never suppresses a later identical Mac copy.
// - Ordering: a send's place in wire order and its local work are fixed
//   together, when it is queued. Its outcome is recorded in the step that
//   learns it, before any later message or anything awaiting the send resumes.
//   Any answer that can reflect the send therefore finds it recorded. A
//   submitted send stays an expected echo across a background revocation; a
//   memory reset (lock, end) discards it.
// - Answers: the Mac's answers carry no request identity. A fetch takes
//   one only once its own request is dispatched: every earlier message is done
//   and the request is handed to the session writer next. An answer before
//   then may be unsolicited or stale and is ignored. A request
//   that is not submitted ends the fetch in the step that learns it. A request
//   whose fetch was abandoned while it waited is never sent.
// - Baseline: while unauthorized the baseline stays unset, whatever
//   is toggled; the next grant sets it. Turning automatic sync on while
//   authorized starts from the current copy. Neither ever uploads earlier content.
// - Automatic reads start only while the session allows them (its
//   scene active, the session running), on every path, deferred ones included.
//   A change seen meanwhile is read on the next activation or check.
// - Empty, unsupported, malformed or oversize content never replaces a
//   valid clipboard. Nothing is persisted or logged; fingerprints live in memory only.

import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// The local pasteboard as the bridge uses it (the general pasteboard in the app).
@MainActor protocol LocalPasteboard: AnyObject {
    /// Readable without a paste prompt.
    var changeCount: Int { get }
    /// Whether shareable content may be present, checked without a paste prompt.
    var mayHaveShareableContent: Bool { get }
    /// Programmatic read: the system may ask the user; empty when not allowed.
    func itemProviders() -> [NSItemProvider]
    /// Replaces the pasteboard with these items, on this device only.
    func write(_ items: [ClipboardItem])
}

@MainActor final class SystemPasteboard: LocalPasteboard {
    private var board: UIPasteboard { .general }
    var changeCount: Int { board.changeCount }
    var mayHaveShareableContent: Bool {
        board.hasStrings || board.hasURLs || board.hasImages
            || board.contains(pasteboardTypes: [ClipboardFormats.rtf, ClipboardFormats.html])
    }
    func itemProviders() -> [NSItemProvider] { board.itemProviders }
    func write(_ items: [ClipboardItem]) {
        // Local only: content of the Mac is not handed on to Universal Clipboard.
        board.setItems(items.map(Self.objects), options: [.localOnly: true])
    }

    private static func objects(_ item: ClipboardItem) -> [String: Any] {
        item.reduce(into: [:]) { out, entry in
            switch entry.key {
            case ClipboardFormats.text: out[entry.key] = String(data: entry.value, encoding: .utf8)
            case ClipboardFormats.url: out[entry.key] = String(data: entry.value, encoding: .utf8).flatMap(URL.init(string:))
            default: out[entry.key] = entry.value
            }
        }
    }
}

/// Loads, per local item, one representation of each kind: one text
/// spelling, the link, RTF, HTML and one image — the provider's
/// highest-fidelity compressed type (its own bytes), TIFF only without one.
/// Equivalent spellings are never all loaded: each load may make UIKit
/// convert. An image is checked from its file (size, then header) before its
/// bytes are read; one that does not fit is left out and the rest of the item
/// is kept. A representation that fails to load is reported, never taken for
/// an empty clipboard. The item providers stay on the main actor; their data
/// arrives on their own queues.
@MainActor
enum LocalClipboardReader {
    struct Loaded: Sendable {
        var items: [ClipboardItem]
        /// Bytes of the largest image left out because it did not fit (nil: none).
        var omittedImage: Int?
    }

    static func load(_ providers: [NSItemProvider], limits: ClipboardLimits, deadline: ClipboardReadDeadline)
        async throws(ClipboardReadStop) -> Result<Loaded, ClipboardIssue> {
        try deadline.check()
        guard providers.count <= limits.items else { return .failure(.tooManyItems(limit: limits.items)) }
        var loaded = Loaded(items: [], omittedImage: nil)
        var total = 0, failures = 0
        for provider in providers {
            let registered = provider.registeredTypeIdentifiers
            var item = ClipboardItem()
            text: for type in ClipboardFormats.localText where registered.contains(type) {
                guard let data = try await data(of: provider, type: type, deadline: deadline) else { failures += 1; continue }
                guard String(data: data, encoding: .utf8) != nil else { continue }
                item[type] = data                                // one spelling only
                break text
            }
            for type in [ClipboardFormats.url, ClipboardFormats.rtf, ClipboardFormats.html] where registered.contains(type) {
                guard let data = try await data(of: provider, type: type, deadline: deadline) else { failures += 1; continue }
                item[type] = data
            }
            total += item.values.reduce(0) { $0 + $1.count }
            // Bounded by what is kept: the local pasteboard gives no size before loading text.
            guard total <= limits.archive else { return .failure(.tooLarge(bytes: total, limit: limits.archive)) }
            if let type = registered.first(where: ClipboardFormats.compressedImages.contains)
                ?? registered.first(where: ClipboardFormats.images.contains) {
                switch try await image(of: provider, type: type, budget: limits.archive - total, limits: limits, deadline: deadline) {
                case .loaded(let data): item[type] = data; total += data.count
                case .tooLarge(let bytes): loaded.omittedImage = max(loaded.omittedImage ?? 0, bytes)
                case .invalid: break                             // not what it claims, or beyond the decoded-image bounds
                case .failed: failures += 1
                }
            }
            loaded.items.append(item)
        }
        try deadline.check()
        if loaded.omittedImage == nil, loaded.items.allSatisfy(\.isEmpty) {
            if failures > 0 { return .failure(.unreadable) }               // never taken for an empty clipboard
            if providers.contains(where: { !$0.registeredTypeIdentifiers.isEmpty }) { return .failure(.unsupported) }
        }
        return .success(loaded)
    }

    /// nil: the representation could not be loaded.
    private static func data(of provider: NSItemProvider, type: String, deadline: ClipboardReadDeadline)
        async throws(ClipboardReadStop) -> Data? {
        try deadline.check()
        return try await ClipboardProviderRead<Data?>(deadline: deadline).value { read in
            if type == ClipboardFormats.url, provider.canLoadObject(ofClass: NSURL.self) {
                return provider.loadObject(ofClass: NSURL.self) { @Sendable [weak read] object, _ in
                    read?.complete { (object as? NSURL)?.absoluteString.map { Data($0.utf8) } }
                }
            }
            return provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable [weak read] data, _ in
                read?.complete { data }
            }
        }
    }

    enum ImageLoad: Equatable, Sendable { case loaded(Data), tooLarge(Int), invalid, failed }

    /// The file exists only during the callback: size and header are checked
    /// there, then the bytes are read. A provider that cannot produce a file is
    /// read as data instead, with the same bounds checked right after loading.
    static func image(of provider: NSItemProvider, type: String, budget: Int, limits: ClipboardLimits,
                      deadline: ClipboardReadDeadline = .init()) async throws(ClipboardReadStop) -> ImageLoad {
        try deadline.check()
        let fromFile = try await ClipboardProviderRead<ImageLoad>(deadline: deadline).value { read in
            provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable [weak read] url, _ in
                read?.complete {
                    guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .failed }
                    guard size <= budget else { return .tooLarge(size) }
                    guard ClipboardFormats.validImage(at: url, type: type, limits: limits) else { return .invalid }
                    guard let data = try? Data(contentsOf: url), data.count == size else { return .failed }
                    return .loaded(data)
                }
            }
        }
        guard fromFile == .failed,
              let data = try await data(of: provider, type: type, deadline: deadline) else { return fromFile }
        guard data.count <= budget else { return .tooLarge(data.count) }
        return ClipboardFormats.validImage(data, type: type, limits: limits) ? .loaded(data) : .invalid
    }
}

@MainActor
@Observable
final class ClipboardBridge {
    /// Off until the user enables it for this Mac.
    static let defaultAutomaticSync = false
    static let noticeDuration: Duration = .seconds(4)
    static let answerTimeout: Duration = .seconds(10)
    /// Sends whose echo may still come back: older ones are forgotten first.
    static let outstandingEchoLimit = 8

    /// Outcome shown to the user; never contains clipboard content.
    enum Notice: Equatable, Sendable {
        case sentToMac, sentWithoutImages, copiedFromMac, alreadyHere
        case nothingToSend, macEmpty
        case unsupportedToSend, unsupportedFromMac, unreadableFromMac, unreadableLocal
        case tooLargeToSend(bytes: Int, limit: Int), tooLargeToReceive(bytes: Int, limit: Int)
        case tooManyItemsToSend(limit: Int), tooManyItemsFromMac(limit: Int)
        case localWorkChanged, automaticSendPaused, automaticReadTimedOut, busy, noAnswer, unavailable

        @MainActor var message: String {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "iPad") : String(localized: "iPhone")
            func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
            return switch self {
            // Sent: handed to the network. The Mac does not acknowledge a pasteboard.
            case .sentToMac: String(localized: "Clipboard sent to the Mac.")
            case .sentWithoutImages:
                String(localized: "Sent to the Mac without its images: they are too large for the Mac session.")
            case .copiedFromMac: String(localized: "Mac clipboard copied to this \(device).")
            case .alreadyHere: String(localized: "This \(device) already has the Mac clipboard.")
            case .nothingToSend: String(localized: "Nothing to send: the clipboard has no text, link, formatted text or image.")
            case .macEmpty: String(localized: "The Mac clipboard is empty. The clipboard of this \(device) was kept.")
            case .unsupportedToSend:
                String(localized: "Not sent: only text, links, formatted text and images can be shared with the Mac.")
            case .unsupportedFromMac:
                String(localized: "The Mac clipboard has no text, link, formatted text or image. The clipboard of this \(device) was kept.")
            case .unreadableFromMac: String(localized: "The Mac clipboard could not be read. The clipboard of this \(device) was kept.")
            case .unreadableLocal: String(localized: "Not sent: the clipboard of this \(device) could not be read.")
            case .tooLargeToSend(let bytes, let limit):
                String(localized: "Not sent: too large for the Mac session (\(size(bytes)); limit \(size(limit))).")
            case .tooLargeToReceive(let bytes, let limit):
                String(localized: "Not copied: the Mac clipboard is too large (\(size(bytes)); limit \(size(limit))).")
            case .tooManyItemsToSend(let limit):
                String(localized: "Not sent: more than \(limit) items were copied.")
            case .tooManyItemsFromMac(let limit):
                String(localized: "Not copied: the Mac clipboard has more than \(limit) items. The clipboard of this \(device) was kept.")
            case .localWorkChanged: String(localized: "Another clipboard operation occurred while receiving. Your clipboard was kept.")
            case .automaticSendPaused:
                String(localized: "Automatic sending is paused: paste was not allowed. Use Send Clipboard to Mac in Options.")
            case .automaticReadTimedOut:
                String(localized: "Automatic sending is paused: reading the clipboard timed out. Use Send Clipboard to Mac in Options, or turn Sync Automatically off and on to resume.")
            case .busy: String(localized: "The clipboard is busy. Try again in a moment.")
            case .noAnswer: String(localized: "The Mac did not send its clipboard.")
            case .unavailable: String(localized: "The clipboard is available while the session is active.")
            }
        }
    }

    private(set) var automaticSync: Bool
    private(set) var isAuthorized = false
    private(set) var notice: Notice?
    /// The system refused, or failed, an automatic read: not tried again in this session.
    private(set) var automaticReadPaused = false

    @ObservationIgnored private var authorization: FeatureAuthorization?
    @ObservationIgnored private var ended = false
    @ObservationIgnored private let pasteboard: any LocalPasteboard
    @ObservationIgnored private let send: @MainActor ([UInt8], FeatureAuthorization) async -> AccessoryOutcome
    @ObservationIgnored private let saveAutomaticSync: @MainActor (Bool) -> Void
    /// Whether an automatic (programmatic) read may start now, as determined by the session.
    @ObservationIgnored private let automaticReadAllowed: @MainActor () -> Bool
    typealias OutboundEncoder = @Sendable ([ClipboardItem], ClipboardLimits, Int) async
        -> Result<ClipboardFormats.Outbound, ClipboardIssue>
    @ObservationIgnored private let encodeOutbound: OutboundEncoder
    @ObservationIgnored private let readDeadline: @MainActor () -> ClipboardReadDeadline
    @ObservationIgnored let limits: ClipboardLimits
    @ObservationIgnored let maxMessage: Int

    /// One copy this bridge handed to the network, at `serial` in wire order.
    private struct SentCopy {
        let fingerprint: ClipboardFingerprint
        let changeCount: Int
        let serial: UInt64
    }

    // Session dedup and freshness memory: in memory only, reset by a device lock.
    @ObservationIgnored private var observedChangeCount: Int?
    @ObservationIgnored private var ownWriteChangeCount: Int?
    /// Sends not yet resolved by an answer to a later request (bounded, oldest first).
    @ObservationIgnored private var outstandingEchoes: [SentCopy] = []
    @ObservationIgnored private var lastApplied: ClipboardFingerprint?
    @ObservationIgnored private var remoteRevision: UInt64 = 0
    /// Advances when a local send starts and when it is queued for the wire.
    @ObservationIgnored private var localWork: UInt64 = 0
    @ObservationIgnored private var wireSerial: UInt64 = 0
    /// Advances at every memory reset: a send from an earlier epoch is never recorded.
    @ObservationIgnored private var memoryEpoch: UInt64 = 0
    private enum Monitoring { case off, pending, on }
    @ObservationIgnored private var monitoring = Monitoring.off
    private struct LocalSend {
        let id: UInt64
        let manual: Bool
        var task: Task<Void, Never>?
        var queuedPayload: ClipboardFormats.Outbound?
    }
    @ObservationIgnored private var localSend: LocalSend?
    @ObservationIgnored private var lastLocalSendID: UInt64 = 0
    @ObservationIgnored private var pendingLocalCheck = false
    @ObservationIgnored private var wireTail: Task<AccessoryOutcome, Never>?
    @ObservationIgnored private var noticeSerial: UInt64 = 0

    private struct Fetch {
        let id: UInt64
        var manual: Bool
        let authorization: FeatureAuthorization
        let localChangeCount: Int
        let localWork: UInt64
        let remoteRevision: UInt64
        /// The request's place in wire order.
        let serial: UInt64
        /// Replies are eligible only after this request is dispatched.
        var dispatched = false
    }
    @ObservationIgnored private var fetch: Fetch?
    @ObservationIgnored private var lastFetchID: UInt64 = 0

    init(automaticSync: Bool, pasteboard: any LocalPasteboard, limits: ClipboardLimits = .standard,
         maxMessage: Int = HPSSSession.accessoryBudget,
         send: @escaping @MainActor ([UInt8], FeatureAuthorization) async -> AccessoryOutcome,
         saveAutomaticSync: @escaping @MainActor (Bool) -> Void,
         automaticReadAllowed: @escaping @MainActor () -> Bool = { true },
         readDeadline: @escaping @MainActor () -> ClipboardReadDeadline = { .init() },
         encodeOutbound: @escaping OutboundEncoder = ClipboardBridge.encode) {
        self.automaticSync = automaticSync
        self.pasteboard = pasteboard
        self.limits = limits
        self.maxMessage = maxMessage
        self.send = send
        self.saveAutomaticSync = saveAutomaticSync
        self.automaticReadAllowed = automaticReadAllowed
        self.readDeadline = readDeadline
        self.encodeOutbound = encodeOutbound
    }

    var hasRequestInFlight: Bool { fetch != nil }
    /// Read-only, for tests: sends whose echo may still come back.
    var outstandingEchoCount: Int { outstandingEchoes.count }
    /// Read-only, for tests: a local send is being read, encoded or written.
    var isSending: Bool { localSend != nil }
    /// Read-only, for tests: messages put in wire order so far.
    var messagesQueued: UInt64 { wireSerial }

    // MARK: lifetime

    func grant(_ granted: FeatureAuthorization) {
        guard !ended else { return }
        authorization = granted
        isAuthorized = true
        enableMonitoring()
        if observedChangeCount == nil {
            observedChangeCount = pasteboard.changeCount   // baseline: earlier content is never sent automatically
        } else {
            // A copy made while this session was in the background: read after
            // the activation completes, never inside the grant itself.
            Task { @MainActor [weak self] in self?.localPasteboardChanged() }
        }
    }

    /// Invalidates every pending operation; a device lock also clears the dedup memory.
    func revoke(_ reason: RevocationReason) {
        authorization = nil
        cancelLocalSend()
        isAuthorized = false
        fetch = nil
        pendingLocalCheck = false
        if reason == .deviceLock { resetMemory() }
    }

    func end() {
        revoke(.sessionEnded)
        ended = true
        resetMemory()
        notice = nil
    }

    private func resetMemory() {
        memoryEpoch &+= 1
        observedChangeCount = nil
        ownWriteChangeCount = nil
        outstandingEchoes.removeAll()
        lastApplied = nil
    }

    /// 0x15 once per session, under the grant in force when it is sent: a
    /// request cancelled by a revocation is made again under the newer grant.
    private func enableMonitoring() {
        guard monitoring == .off, let granted = authorization else { return }
        monitoring = .pending
        let done = enqueue(ClipboardWire.autoPasteboardEnable, granted).done
        Task { @MainActor in
            let outcome = await done.value
            guard !ended, monitoring == .pending else { return }
            monitoring = outcome == .submitted ? .on : .off
            if monitoring == .off, let current = authorization, current != granted { enableMonitoring() }
        }
    }

    // MARK: commands

    func setAutomaticSync(_ on: Bool) {
        guard !ended, on != automaticSync else { return }
        automaticSync = on
        saveAutomaticSync(on)
        if on {
            automaticReadPaused = false
            // Only copies made from now on. Unauthorized (before the first grant,
            // after a lock or a background): unset, so the next grant sets it.
            observedChangeCount = authorization != nil ? pasteboard.changeCount : nil
        } else {
            pendingLocalCheck = false
            if fetch?.manual == false { fetch = nil }
            if localSend?.manual == false { cancelLocalSend() }
        }
    }

    /// Send local: items from the system paste control.
    func sendManual(_ providers: [NSItemProvider]) {
        guard let current = authorization else { return post(.unavailable) }
        guard !providers.isEmpty else { return post(.nothingToSend) }
        guard !isSending else { return post(.busy) }
        let count = pasteboard.changeCount
        observedChangeCount = count                        // handled: automatic sync does not resend it
        sendLocal(changeCount: count, manual: true, authorization: current) { providers }
    }

    /// Receive current Mac.
    func receiveManual() {
        guard let current = authorization else { return post(.unavailable) }
        if fetch != nil { fetch?.manual = true; return }
        startFetch(manual: true, current)
    }

    // MARK: local → Mac

    /// The local pasteboard changed, the scene became active again, or the
    /// session's once-a-second check: reads only if the change count moved.
    func localPasteboardChanged() {
        guard let current = authorization, automaticSync, !automaticReadPaused else { return }
        guard automaticReadAllowed() else { return }      // An inactive scene leaves the change unobserved.
        let count = pasteboard.changeCount
        guard count != observedChangeCount else { return }
        guard count != ownWriteChangeCount else { observedChangeCount = count; return } // the bridge's own write
        guard !isSending else { pendingLocalCheck = true; return }
        observedChangeCount = count                       // at most one read per change: no repeated prompt
        guard pasteboard.mayHaveShareableContent else { return } // nothing shareable: the Mac keeps its clipboard
        sendLocal(changeCount: count, manual: false, authorization: current) {
            pasteboard.itemProviders()                            // the system may ask the user here
        }
    }

    private func pauseAutomaticReads(_ notice: Notice = .automaticSendPaused) {
        automaticReadPaused = true
        post(notice)
    }

    private func sendLocal(changeCount: Int, manual: Bool, authorization granted: FeatureAuthorization,
                           readProviders: () -> [NSItemProvider]) {
        lastLocalSendID &+= 1
        let id = lastLocalSendID
        localSend = LocalSend(id: id, manual: manual)
        localWork &+= 1                                    // an answer requested before this is older
        let providers = readProviders()
        guard localSend?.id == id else { return }
        guard !providers.isEmpty else {
            pauseAutomaticReads()
            sendEnded(id)
            return
        }
        let deadline = readDeadline()
        let limits = self.limits, maxMessage = self.maxMessage, epoch = memoryEpoch
        localSend?.task = Task { @MainActor in
            var queued = false
            defer { if !queued { sendEnded(id) } }
            let loaded: Result<LocalClipboardReader.Loaded, ClipboardIssue>
            do throws(ClipboardReadStop) {
                loaded = try await LocalClipboardReader.load(providers, limits: limits, deadline: deadline)
            } catch {
                guard error == .timedOut, localSend?.id == id else { return }
                // The system prompt can outlive the timed-out read.
                // Pause automatic reads so the same copy cannot prompt again.
                if manual { post(.unreadableLocal) } else { pauseAutomaticReads(.automaticReadTimedOut) }
                return
            }
            guard localSend?.id == id, authorization == granted else { return }
            let encoded: Result<ClipboardFormats.Outbound, ClipboardIssue>
            switch loaded {
            case .failure(let issue): encoded = .failure(issue)
            case .success(let local) where local.items.allSatisfy(\.isEmpty) && local.omittedImage != nil:
                encoded = .failure(.tooLarge(bytes: local.omittedImage ?? 0, limit: maxMessage))
            case .success(let local):
                let result = await encodeOutbound(local.items, limits, maxMessage)
                encoded = result.map { .init(message: $0.message, fingerprint: $0.fingerprint,
                                             omittedImages: $0.omittedImages || local.omittedImage != nil) }
            }
            guard localSend?.id == id, authorization == granted else { return }
            let payload: ClipboardFormats.Outbound
            switch encoded {
            case .success(let value): payload = value
            case .failure(.empty): if manual { post(.nothingToSend) }; return
            case .failure(.unsupported): post(.unsupportedToSend); return
            case .failure(.tooLarge(let bytes, let limit)): post(.tooLargeToSend(bytes: bytes, limit: limit)); return
            case .failure(.tooManyItems(let limit)): post(.tooManyItemsToSend(limit: limit)); return
            case .failure(.malformed): if manual { post(.nothingToSend) }; return
            case .failure(.unreadable):
                // Possibly a refused paste: automatic reads stop, the paste control remains.
                if manual { post(.unreadableLocal) } else { pauseAutomaticReads() }
                return
            }
            // A newer local copy arrived meanwhile: it supersedes this one.
            if !manual, pasteboard.changeCount != changeCount { pendingLocalCheck = true; return }
            // Its local work and its place in wire order are fixed together, in
            // this step: an answer to an earlier request is older than this send.
            localWork &+= 1
            queued = true
            localSend?.task = nil
            localSend?.queuedPayload = payload
            var dispatched: ClipboardFormats.Outbound?
            enqueue(granted, message: { [self] in
                guard localSend?.id == id else { return nil }
                dispatched = localSend?.queuedPayload
                localSend?.queuedPayload = nil
                return dispatched?.message
            }, completion: { [self] serial, outcome in
                if let dispatched {
                    record(outcome, of: dispatched, serial: serial, changeCount: changeCount, manual: manual,
                           granted: granted, epoch: epoch)
                }
                sendEnded(id)
            })
        }
    }

    @concurrent private static func encode(_ items: [ClipboardItem], _ limits: ClipboardLimits, _ maxMessage: Int)
        async -> Result<ClipboardFormats.Outbound, ClipboardIssue> {
        ClipboardFormats.encodeOutbound(items, limits: limits, maxMessage: maxMessage)
    }

    /// Record the outcome before another clipboard message can be dispatched.
    private func record(_ outcome: AccessoryOutcome, of payload: ClipboardFormats.Outbound, serial: UInt64, changeCount: Int,
                        manual: Bool, granted: FeatureAuthorization, epoch: UInt64) {
        // Handed to the network: its echo may still come back, even after a
        // background revocation. Never recorded across a memory reset (lock, end).
        if outcome == .submitted, epoch == memoryEpoch {
            outstandingEchoes.append(SentCopy(fingerprint: payload.fingerprint, changeCount: changeCount, serial: serial))
            if outstandingEchoes.count > Self.outstandingEchoLimit { outstandingEchoes.removeFirst() }
        }
        guard authorization == granted else { return }    // notices only under the grant it was sent with
        switch outcome {
        case .submitted: if payload.omittedImages { post(.sentWithoutImages) } else if manual { post(.sentToMac) }
        case .tooLarge(let limit): post(.tooLargeToSend(bytes: payload.message.count, limit: limit))
        case .busy: post(.busy)
        case .unavailable: if manual { post(.unavailable) }
        case .cancelled, .failed: break                   // revoked or ending: nothing to report
        }
    }

    private func cancelLocalSend() {
        let task = localSend?.task
        localSend = nil
        task?.cancel()
    }

    private func sendEnded(_ id: UInt64) {
        guard localSend?.id == id else { return }
        localSend = nil
        if pendingLocalCheck { pendingLocalCheck = false; localPasteboardChanged() }
    }

    // MARK: Mac → local

    func handle(_ event: ClipboardEvent) {
        guard !ended else { return }
        switch event {
        case .remoteChanged:
            remoteRevision &+= 1
            guard let current = authorization, automaticSync, fetch == nil else { return }
            startFetch(manual: false, current)
        case .oversize(let compressed):
            guard let request = fetch, request.dispatched, request.authorization == authorization else { return }
            fetch = nil
            post(.tooLargeToReceive(bytes: compressed, limit: limits.inboundCompressed))
        case .content(let message):
            // Unsolicited, early or late answers (no dispatched request of this grant) are ignored.
            guard let request = fetch, request.dispatched, request.authorization == authorization else { return }
            let limits = self.limits
            Task { @MainActor in
                let decoded = await Task.detached(priority: .userInitiated) {
                    ClipboardFormats.decodeInbound(message, limits: limits)
                }.value
                apply(decoded, answering: request.id)
            }
        }
    }

    private func startFetch(manual: Bool, _ granted: FeatureAuthorization) {
        lastFetchID &+= 1
        let id = lastFetchID
        // Both callbacks act on this fetch only: an earlier fetch's never mark or end a newer one.
        let (serial, done) = enqueue(ClipboardWire.request, granted, completion: { [self] _, outcome in
            // Not handed to the network: ended in the step that learns it, so no
            // later message is taken for its answer.
            guard outcome != .submitted, let request = fetch, request.id == id else { return }
            fetch = nil
            if request.manual { post(outcome == .busy ? .busy : .unavailable) }
        }, dispatching: { [self] in
            // Only the live fetch's request is sent: an abandoned one is cancelled here.
            guard fetch?.id == id else { return false }
            fetch?.dispatched = true
            return true
        })
        fetch = Fetch(id: id, manual: manual, authorization: granted, localChangeCount: pasteboard.changeCount,
                      localWork: localWork, remoteRevision: remoteRevision, serial: serial)
        Task { @MainActor in
            guard await done.value == .submitted, fetch?.id == id else { return }
            try? await Task.sleep(for: Self.answerTimeout)
            guard let pending = fetch, pending.id == id else { return }
            fetch = nil
            if pending.manual { post(.noAnswer) }
        }
    }

    private func apply(_ decoded: Result<(items: [ClipboardItem], fingerprint: ClipboardFingerprint), ClipboardIssue>,
                       answering id: UInt64) {
        guard let request = fetch, request.id == id, request.authorization == authorization else { return }
        fetch = nil
        let manual = request.manual
        if remoteRevision != request.remoteRevision {
            // The Mac announced a newer copy meanwhile: this answer may predate it.
            if manual || automaticSync { startFetch(manual: manual, request.authorization) }
            return
        }
        let current = pasteboard.changeCount
        let freshnessOK = current == request.localChangeCount || current == ownWriteChangeCount
        guard manual || freshnessOK,
              localWork == request.localWork, !isSending else {
            if manual { post(isSending ? .busy : .localWorkChanged) }
            return
        }
        switch decoded {
        case .failure(.empty): if manual { post(.macEmpty) }
        case .failure(.unsupported): post(.unsupportedFromMac)
        case .failure(.tooLarge(let bytes, let limit)): post(.tooLargeToReceive(bytes: bytes, limit: limit))
        case .failure(.tooManyItems(let limit)): post(.tooManyItemsFromMac(limit: limit))
        case .failure(.malformed), .failure(.unreadable): post(.unreadableFromMac)
        case .success(let content):
            // The sends this answer can reflect are those before its request:
            // it resolves them, whether or not it is one of them.
            let resolved = outstandingEchoes.filter { $0.serial < request.serial }
            outstandingEchoes.removeAll { $0.serial < request.serial }
            if let echo = resolved.last(where: { $0.fingerprint.isCovered(by: content.fingerprint) }) {
                guard manual else { return }                // the Mac reports the bridge's own copy
                if echo.changeCount == current { return post(.alreadyHere) } // this device still has what it sent
            }
            if lastApplied == content.fingerprint, current == ownWriteChangeCount {
                if manual { post(.alreadyHere) }            // unchanged since the bridge wrote it
                return
            }
            pasteboard.write(content.items)
            ownWriteChangeCount = pasteboard.changeCount
            observedChangeCount = ownWriteChangeCount
            lastApplied = content.fingerprint
            if manual { post(.copiedFromMac) }
        }
    }

    // MARK: helpers

    @discardableResult
    private func enqueue(_ message: [UInt8], _ granted: FeatureAuthorization,
                         completion: @escaping @MainActor (_ serial: UInt64, AccessoryOutcome) -> Void = { _, _ in },
                         dispatching: @escaping @MainActor () -> Bool = { true })
        -> (serial: UInt64, done: Task<AccessoryOutcome, Never>) {
        enqueue(granted, message: { dispatching() ? message : nil }, completion: completion)
    }

    /// Serial and queue position are assigned together. Resolve the message
    /// after all earlier writes and immediately before handing it to the
    /// session. Completion observes the outcome before the next write.
    @discardableResult
    private func enqueue(_ granted: FeatureAuthorization, message: @escaping @MainActor () -> [UInt8]?,
                         completion: @escaping @MainActor (_ serial: UInt64, AccessoryOutcome) -> Void)
        -> (serial: UInt64, done: Task<AccessoryOutcome, Never>) {
        wireSerial &+= 1
        let serial = wireSerial, previous = wireTail
        let next = Task { @MainActor in
            _ = await previous?.value
            let outcome: AccessoryOutcome
            if authorization == granted, let message = message() {
                outcome = await send(message, granted)
            } else {
                outcome = .cancelled
            }
            completion(serial, outcome)
            return outcome
        }
        wireTail = next
        return (serial, next)
    }

    private func post(_ value: Notice) {
        noticeSerial &+= 1
        let serial = noticeSerial
        notice = value
        Task { @MainActor in
            try? await Task.sleep(for: Self.noticeDuration)
            if noticeSerial == serial { notice = nil }
        }
    }
}
