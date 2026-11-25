// Vicinia — on-demand session toolbar: visibility, automatic dismissal, the
// one-time gesture hint and the pointer-lock preference that follows them.
// Presentation state only: it never touches the renderer, the viewport,
// remote input or the HPSS session.
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SessionToolbar {
    /// Runs `action` once after `delay`; the returned closure cancels it.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// `pending` until the first desktop is presented, then `established`
    /// (immersive) until the session ends. Never goes back.
    enum Stage { case pending, established, ended }

    static let autoHideDelay: Duration = .seconds(5)
    static let hintDuration: Duration = .seconds(7)
    static let hintShownKey = "sessionToolbarHintShown"

    /// Pinned while connecting and after the session ended, so Close is always
    /// reachable; on demand while the session is established.
    private(set) var isVisible = true
    /// Optional activation point (window coordinates) from the two-finger double
    /// tap that opened the radial controls; `nil` uses the default placement.
    /// Kept across hiding so the dismissal animation finishes in place.
    private(set) var anchorPoint: CGPoint?
    private(set) var showsHint = false
    /// Pointer lock is requested only while immersive. The system pointer stays
    /// local while the toolbar is visible, so a mouse or trackpad can operate
    /// it; the lock returns once the toolbar is hidden and no remote button is
    /// held, so no press is split between the local and the locked pointer. A
    /// remote press never releases the lock.
    private(set) var prefersPointerLock = false
    private(set) var stage = Stage.pending
    /// The session menu is open: dismissing would close it under the user.
    @ObservationIgnored private(set) var isMenuOpen = false
    /// Toolbar controls currently pressed (touch, mouse or trackpad).
    @ObservationIgnored private var pressedControls: Set<ObjectIdentifier> = []
    @ObservationIgnored private var remoteButtonHeld = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var dismissal: Pending?
    @ObservationIgnored private var hintExpiry: Pending?
    @ObservationIgnored private var token: UInt64 = 0
    @ObservationIgnored private let schedule: Schedule
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let assistiveTechnologyRunning: @MainActor () -> Bool

    private struct Pending {
        let token: UInt64
        let cancel: @MainActor () -> Void
    }

    init(defaults: UserDefaults = .standard,
         assistiveTechnologyRunning: @escaping @MainActor () -> Bool = {
             UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
         },
         schedule: @escaping Schedule = SessionToolbar.liveSchedule) {
        self.defaults = defaults
        self.assistiveTechnologyRunning = assistiveTechnologyRunning
        self.schedule = schedule
    }

    static func liveSchedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            action()
        }
        return { task.cancel() }
    }

    var isDismissalPending: Bool { dismissal != nil }
    var isControlPressed: Bool { !pressedControls.isEmpty }
    /// True only when the controls may be dismissed locally (not while
    /// connecting or after the session has ended).
    var canDismiss: Bool { stage == .established && isVisible }

    /// First presented desktop: show the toolbar, start the timeout and,
    /// once per installation, the gesture hint.
    func sessionEstablished(offeringHint: Bool) {
        guard stage == .pending else { return }
        stage = .established
        anchorPoint = nil
        setVisible(true)
        restartDismissal()
        guard offeringHint, !defaults.bool(forKey: Self.hintShownKey) else { return }
        defaults.set(true, forKey: Self.hintShownKey) // recorded when shown: never twice, even after a crash
        showsHint = true
        token &+= 1
        let token = self.token
        let cancel = schedule(Self.hintDuration) { [weak self] in
            guard let self, hintExpiry?.token == token else { return }
            endHint()
        }
        hintExpiry = Pending(token: token, cancel: cancel)
    }

    /// Termination, disconnection or view disposal: nothing stays scheduled.
    func sessionEnded() {
        guard stage != .ended else { return }
        stage = .ended
        cancelDismissal()
        endHint()
        isMenuOpen = false
        pressedControls.removeAll()
        anchorPoint = nil
        setVisible(true)
    }

    /// Two-finger double tap and the accessibility actions.
    func toggle(at anchor: CGPoint? = nil) {
        guard stage == .established else { return }
        endHint()
        if isVisible {
            hide()
        } else {
            anchorPoint = anchor
            setVisible(true)
            restartDismissal()
        }
    }

    /// Explicit local dismissal from the radial center hub or an outside tap.
    /// Never hides the controls while connecting or after the session ended.
    func dismiss() {
        guard stage == .established, isVisible else { return }
        endHint()
        hide()
    }

    /// A toolbar control was used: a full timeout starts again.
    func controlUsed() {
        guard stage == .established, isVisible else { return }
        restartDismissal()
    }

    func setMenuOpen(_ open: Bool) {
        isMenuOpen = open && isVisible
        restartDismissal()
    }

    /// A toolbar control press began, or ended (released or cancelled). While
    /// any control is pressed nothing dismisses the toolbar automatically; the
    /// release starts a full timeout. Only a visible toolbar records a press,
    /// and hiding or ending clears them, so no stale press can outlive it.
    func setControlPressed(_ pressed: Bool, control: ObjectIdentifier) {
        if pressed, stage != .ended, isVisible { pressedControls.insert(control) } else { pressedControls.remove(control) }
        restartDismissal()
    }

    /// Fed by the controller at transitions of the remote button state.
    func setRemoteButtonHeld(_ held: Bool) {
        remoteButtonHeld = held
        updatePointerLock()
    }

    /// An intentional remote action (click, press, scroll, typing) dismisses
    /// the toolbar; the action itself is delivered unchanged by the caller.
    func remoteInteraction() {
        guard stage == .established, isVisible, !isMenuOpen, pressedControls.isEmpty, !assistiveTechnologyRunning() else { return }
        hide()
    }

    /// Inactive scene: no dismissal runs in the background; a full timeout
    /// starts again on return.
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        restartDismissal()
    }

    /// VoiceOver or Switch Control started or stopped.
    func assistiveTechnologyChanged() { restartDismissal() }

    private func hide() {
        cancelDismissal()
        isMenuOpen = false
        pressedControls.removeAll()
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        updatePointerLock()
    }

    private func updatePointerLock() {
        let preferred = !isVisible && (prefersPointerLock || !remoteButtonHeld)
        if preferred != prefersPointerLock { prefersPointerLock = preferred }
    }

    private func endHint() {
        hintExpiry?.cancel()
        hintExpiry = nil
        showsHint = false
    }

    private func cancelDismissal() {
        dismissal?.cancel()
        dismissal = nil
    }

    /// At most one pending dismissal; a stale or cancelled callback is a no-op.
    /// With VoiceOver or Switch Control running, only explicit requests hide
    /// the toolbar, so focus is never pulled from under the user.
    private func restartDismissal() {
        cancelDismissal()
        guard stage == .established, isVisible, !isMenuOpen, pressedControls.isEmpty, sceneActive,
              !assistiveTechnologyRunning() else { return }
        token &+= 1
        let token = self.token
        let cancel = schedule(Self.autoHideDelay) { [weak self] in
            guard let self, dismissal?.token == token else { return }
            dismissal = nil
            guard !isMenuOpen, pressedControls.isEmpty, !assistiveTechnologyRunning() else { return }
            hide()
        }
        dismissal = Pending(token: token, cancel: cancel)
    }
}
