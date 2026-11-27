// Vicinia — app-scoped single live-session ownership.
// SPDX-License-Identifier: MIT
//
// One live session per app, from connect until its teardown has completed:
// with several scenes, the local pasteboard and the fixed media ports are
// shared, so a second concurrent session could carry one Mac's clipboard to
// another. The claim is taken where the request is made, before any side
// effect (settings, credentials, presentation), and the session controller
// accepts a live source only with a claim this slot still holds. Main-actor
// serial: a claim is a single check-and-set, so two windows cannot both win.
// A request made while the predecessor is tearing down is accepted, but
// connects (and binds media) only after that teardown has completed, and
// gives up after a bounded wait instead of waiting forever.

import Foundation

@MainActor
final class LiveSessionSlot {
    static let shared = LiveSessionSlot()
    /// The longest a successor waits for its predecessor's teardown.
    let predecessorTimeout: Duration

    init(predecessorTimeout: Duration = .seconds(15)) { self.predecessorTimeout = predecessorTimeout }

    struct Claim: Hashable, Sendable { fileprivate let id = UUID() }

    private var live: Claim?
    private var ending: Set<Claim> = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var isLive: Bool { live != nil }
    var isTearingDown: Bool { !ending.isEmpty }

    /// nil: another session is live; refuse without side effects.
    func claim() -> Claim? {
        guard live == nil else { return nil }
        let claim = Claim()
        live = claim
        return claim
    }

    /// Whether `claim` is the live one (the session boundary's check).
    func holds(_ claim: Claim) -> Bool { live == claim }

    /// The owner's session is ending: a successor may claim, and waits.
    func beginTeardown(_ claim: Claim) {
        guard live == claim else { return }
        live = nil
        ending.insert(claim)
    }

    /// Teardown completed (or there never was a session). Idempotent.
    func finish(_ claim: Claim) {
        if live == claim { live = nil }
        ending.remove(claim)
        guard ending.isEmpty else { return }
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed.values { waiter.resume(returning: true) }
    }

    /// true once no predecessor is tearing down; false after `timeout` or when
    /// the waiting task is cancelled (the successor then gives up, explicitly).
    func awaitPredecessors() async -> Bool {
        guard !ending.isEmpty else { return true }
        let id = UUID(), timeout = predecessorTimeout
        let expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolve(id, false)
        }
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { c.resume(returning: false) } else { waiters[id] = c }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, false) }
        }
    }

    private func resolve(_ id: UUID, _ value: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }
}
