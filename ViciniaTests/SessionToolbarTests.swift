// Vicinia tests — immersive session controls: toolbar state and lifecycle,
// one-time gesture hint, local gesture/shortcut/accessibility toggles that
// never reach the Mac, and toolbar transitions that leave the surface alone.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Vicinia

/// Deterministic `SessionToolbar.Schedule`: callbacks run only when a test fires them.
@MainActor
final class ManualSchedule {
    final class Entry {
        let delay: Duration
        let action: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(delay: Duration, action: @escaping @MainActor () -> Void) { self.delay = delay; self.action = action }
        var live: Bool { !cancelled && !fired }
    }

    private(set) var entries: [Entry] = []
    var live: [Entry] { entries.filter(\.live) }

    var schedule: SessionToolbar.Schedule {
        { delay, action in // retains self: a toolbar may own the only reference
            let entry = Entry(delay: delay, action: action)
            self.entries.append(entry)
            return { entry.cancelled = true }
        }
    }

    /// Runs a callback as the live scheduler would, even a cancelled (stale) one.
    func fire(_ entry: Entry) {
        entry.fired = true
        entry.action()
    }
}

/// An isolated defaults domain, removed by `remove()`.
final class TestDefaults: @unchecked Sendable {
    let suite = "vicinia.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    func remove() { defaults.removePersistentDomain(forName: suite) }
}

/// Feeds a deterministic recognizer state through the production target/action.
@MainActor
final class TapSample: UITapGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .ended
    var point = CGPoint(x: 120, y: 90)
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    func send(to view: DesktopView, _ selector: String, _ state: UIGestureRecognizer.State = .ended) {
        sampleState = state
        _ = view.perform(NSSelectorFromString(selector), with: self)
    }
}

@MainActor
private func makeToolbar(_ schedule: ManualSchedule, defaults: UserDefaults = TestDefaults().defaults,
                         assistive: @escaping @MainActor () -> Bool = { false }) -> SessionToolbar {
    SessionToolbar(defaults: defaults, assistiveTechnologyRunning: assistive, schedule: schedule.schedule)
}

@Suite("Session toolbar state")
@MainActor
struct SessionToolbarStateTests {
    @Test func pinnedWhileConnectingThenShownAndHiddenAfterFiveSeconds() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        #expect(toolbar.stage == .pending && toolbar.isVisible && !toolbar.isDismissalPending)
        toolbar.toggle(); toolbar.remoteInteraction(); toolbar.controlUsed()
        #expect(toolbar.isVisible && timers.entries.isEmpty) // Close stays reachable while connecting
        toolbar.sessionEstablished(offeringHint: false)
        #expect(toolbar.stage == .established && toolbar.isVisible)
        let dismissal = try #require(timers.live.first)
        #expect(timers.live.count == 1 && dismissal.delay == .seconds(5))
        timers.fire(dismissal)
        #expect(!toolbar.isVisible && !toolbar.isDismissalPending && timers.live.isEmpty)
    }

    @Test func explicitToggleShowsWithAFreshTimeoutAndHidesImmediately() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let first = try #require(timers.live.first)
        toolbar.toggle()
        #expect(!toolbar.isVisible && first.cancelled && timers.live.isEmpty)
        toolbar.toggle()
        let recalled = try #require(timers.live.first)
        #expect(toolbar.isVisible && timers.live.count == 1 && recalled.delay == .seconds(5))
        timers.fire(first) // a cancelled callback that still runs is stale
        #expect(toolbar.isVisible && toolbar.isDismissalPending)
        timers.fire(recalled)
        #expect(!toolbar.isVisible)
    }

    @Test func controlUseRestartsTheTimeout() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let first = try #require(timers.live.first)
        toolbar.controlUsed()
        let second = try #require(timers.live.first)
        #expect(first.cancelled && timers.live.count == 1 && second.delay == .seconds(5))
        timers.fire(first)
        #expect(toolbar.isVisible)
        timers.fire(second)
        #expect(!toolbar.isVisible)
        toolbar.controlUsed() // hidden: nothing to restart
        #expect(timers.live.isEmpty && !toolbar.isVisible)
    }

    @Test func intentionalRemoteInteractionDismisses() {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        toolbar.remoteInteraction()
        #expect(!toolbar.isVisible && timers.live.isEmpty)
        toolbar.remoteInteraction()
        #expect(!toolbar.isVisible && timers.live.isEmpty)
    }

    @Test func openMenuSuspendsEveryAutomaticDismissal() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let pending = try #require(timers.live.first)
        toolbar.setMenuOpen(true)
        #expect(pending.cancelled && timers.live.isEmpty && toolbar.isMenuOpen)
        timers.fire(pending)
        toolbar.remoteInteraction()
        #expect(toolbar.isVisible)
        toolbar.setMenuOpen(false)
        #expect(!toolbar.isMenuOpen && timers.live.count == 1 && timers.live.first?.delay == .seconds(5))
        // An explicit toggle still hides at once and cannot leave the menu flag stuck.
        toolbar.setMenuOpen(true)
        toolbar.toggle()
        #expect(!toolbar.isVisible && !toolbar.isMenuOpen)
        toolbar.setMenuOpen(true) // a late callback for a hidden toolbar
        #expect(!toolbar.isMenuOpen && timers.live.isEmpty)
    }

    @Test func rapidTogglesLeaveOneConsistentState() {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        for i in 1...101 {
            toolbar.toggle()
            #expect(toolbar.isVisible == (i % 2 == 0))
            #expect(timers.live.count == (toolbar.isVisible ? 1 : 0))
        }
        #expect(!toolbar.isVisible)
        for entry in timers.entries { timers.fire(entry) } // every callback is stale now
        #expect(!toolbar.isVisible && !toolbar.isDismissalPending)
        toolbar.toggle()
        #expect(toolbar.isVisible && timers.live.count == 1)
    }

    @Test func sessionEndCancelsPendingWorkAndIgnoresLateCallbacks() throws {
        let timers = ManualSchedule(), store = TestDefaults(), toolbar = makeToolbar(timers, defaults: store.defaults)
        defer { store.remove() }
        toolbar.sessionEstablished(offeringHint: true)
        #expect(timers.live.count == 2) // dismissal and hint
        toolbar.sessionEnded()
        #expect(timers.live.isEmpty && timers.entries.allSatisfy(\.cancelled))
        #expect(toolbar.stage == .ended && toolbar.isVisible && !toolbar.showsHint && !toolbar.isDismissalPending)
        for entry in timers.entries { timers.fire(entry) }
        toolbar.toggle(); toolbar.remoteInteraction(); toolbar.controlUsed(); toolbar.setSceneActive(true)
        toolbar.sessionEstablished(offeringHint: true) // never re-enters immersive mode
        #expect(toolbar.stage == .ended && toolbar.isVisible && !toolbar.showsHint && timers.live.isEmpty)
        toolbar.sessionEnded() // idempotent
        #expect(toolbar.stage == .ended)
    }

    @Test func inactiveSceneCancelsAndReturnRestartsTheTimeout() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let pending = try #require(timers.live.first)
        toolbar.setSceneActive(false)
        #expect(pending.cancelled && timers.live.isEmpty && toolbar.isVisible)
        toolbar.toggle(); toolbar.toggle() // explicit requests still work while inactive
        #expect(toolbar.isVisible && timers.live.isEmpty)
        toolbar.setSceneActive(true)
        #expect(timers.live.count == 1 && timers.live.first?.delay == .seconds(5))
    }

    @Test func assistiveTechnologyKeepsTheToolbarUntilExplicitlyHidden() throws {
        var running = true
        let timers = ManualSchedule(), toolbar = makeToolbar(timers, assistive: { running })
        toolbar.sessionEstablished(offeringHint: false)
        #expect(toolbar.isVisible && timers.live.isEmpty)
        toolbar.remoteInteraction()
        #expect(toolbar.isVisible)
        toolbar.toggle()
        #expect(!toolbar.isVisible) // the accessibility action still hides it
        toolbar.toggle()
        #expect(toolbar.isVisible && timers.live.isEmpty)
        running = false
        toolbar.assistiveTechnologyChanged()
        let pending = try #require(timers.live.first)
        running = true // VoiceOver started again before the timeout
        timers.fire(pending)
        #expect(toolbar.isVisible)
    }

    @Test func sessionsDoNotShareToolbarState() throws {
        let timers = ManualSchedule()
        let first = makeToolbar(timers), second = makeToolbar(timers)
        first.sessionEstablished(offeringHint: false)
        first.toggle()
        first.sessionEnded()
        #expect(second.stage == .pending && second.isVisible && !second.isDismissalPending)
        second.sessionEstablished(offeringHint: false)
        #expect(second.isVisible && timers.live.count == 1)
        #expect(SessionController().toolbar !== SessionController().toolbar)
    }

    @Test func liveScheduleFiresOnceAndCancels() async {
        var fired = 0, cancelledFired = 0
        _ = SessionToolbar.liveSchedule(.milliseconds(20)) { fired += 1 }
        let cancel = SessionToolbar.liveSchedule(.milliseconds(20)) { cancelledFired += 1 }
        cancel()
        let deadline = ContinuousClock.now + .seconds(2)
        while fired == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(fired == 1 && cancelledFired == 0)
    }

    // MARK: Control presses

    @Test func pressJustBeforeTheTimeoutKeepsTheToolbarUntilReleased() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers), control = NSObject()
        toolbar.sessionEstablished(offeringHint: false)
        let deadline = try #require(timers.live.first)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        #expect(toolbar.isControlPressed && deadline.cancelled && timers.live.isEmpty)
        timers.fire(deadline)         // the original deadline passes during the press
        toolbar.remoteInteraction()   // and another finger acts on the desktop
        #expect(toolbar.isVisible && timers.live.isEmpty)
        toolbar.setControlPressed(false, control: ObjectIdentifier(control))
        let restarted = try #require(timers.live.first)
        #expect(!toolbar.isControlPressed && timers.live.count == 1 && restarted.delay == .seconds(5))
        timers.fire(restarted)
        #expect(!toolbar.isVisible)
    }

    @Test func consecutiveAndOverlappingPressesLeaveOneTimeout() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers), esc = NSObject(), fit = NSObject()
        toolbar.sessionEstablished(offeringHint: false)
        for _ in 0..<3 { // released or cancelled: the same boundary
            toolbar.setControlPressed(true, control: ObjectIdentifier(esc))
            #expect(timers.live.isEmpty)
            toolbar.setControlPressed(false, control: ObjectIdentifier(esc))
            #expect(timers.live.count == 1)
        }
        toolbar.setControlPressed(true, control: ObjectIdentifier(esc))
        toolbar.setControlPressed(true, control: ObjectIdentifier(fit))
        toolbar.setControlPressed(true, control: ObjectIdentifier(fit)) // a repeated begin counts once
        toolbar.setControlPressed(false, control: ObjectIdentifier(esc))
        #expect(toolbar.isControlPressed && timers.live.isEmpty)        // waits for the last release
        toolbar.setControlPressed(false, control: ObjectIdentifier(fit))
        toolbar.setControlPressed(false, control: ObjectIdentifier(fit)) // a duplicate end is harmless
        #expect(!toolbar.isControlPressed && timers.live.count == 1)
        for entry in timers.entries.dropLast() { timers.fire(entry) }    // every earlier deadline is stale
        #expect(toolbar.isVisible)
    }

    @Test func overlappingSuspensionReasonsMustAllClear() {
        var running = false
        let timers = ManualSchedule(), toolbar = makeToolbar(timers, assistive: { running }), control = NSObject()
        toolbar.sessionEstablished(offeringHint: false)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        toolbar.setMenuOpen(true)
        toolbar.setSceneActive(false)
        running = true; toolbar.assistiveTechnologyChanged()
        toolbar.setControlPressed(false, control: ObjectIdentifier(control))
        toolbar.setMenuOpen(false)
        toolbar.setSceneActive(true)
        #expect(timers.live.isEmpty && toolbar.isVisible) // VoiceOver or Switch Control still running
        running = false; toolbar.assistiveTechnologyChanged()
        #expect(timers.live.count == 1)
    }

    @Test func inactivityDuringAPressWaitsForBothToEnd() {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers), control = NSObject()
        toolbar.sessionEstablished(offeringHint: false)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        toolbar.setSceneActive(false)                                        // a call or Control Center
        toolbar.setControlPressed(false, control: ObjectIdentifier(control)) // UIKit cancels the touch
        #expect(timers.live.isEmpty && toolbar.isVisible)
        toolbar.setSceneActive(true)
        #expect(timers.live.count == 1)
    }

    @Test func hidingOrEndingDuringAPressLeavesNoStaleSuspension() {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers), control = NSObject()
        toolbar.sessionEstablished(offeringHint: false)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        toolbar.toggle() // an explicit hide still works during a press
        #expect(!toolbar.isVisible && !toolbar.isControlPressed)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control)) // a late event for a hidden toolbar
        #expect(!toolbar.isControlPressed)
        toolbar.toggle()
        #expect(toolbar.isVisible && timers.live.count == 1) // the old press blocks nothing
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        toolbar.sessionEnded()
        #expect(!toolbar.isControlPressed && timers.live.isEmpty)
        toolbar.setControlPressed(true, control: ObjectIdentifier(control))
        #expect(!toolbar.isControlPressed && timers.live.isEmpty)
        let next = makeToolbar(timers) // the next session starts clean
        next.sessionEstablished(offeringHint: false)
        #expect(!next.isControlPressed && timers.live.count == 1)
    }

    // MARK: Pointer ownership

    @Test func pointerLockOnlyWhileImmersiveAndNeverAcrossAHeldButton() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        #expect(!toolbar.prefersPointerLock) // connecting: Close must stay clickable
        toolbar.sessionEstablished(offeringHint: false)
        #expect(!toolbar.prefersPointerLock) // shown with the first desktop
        timers.fire(try #require(timers.live.first))
        #expect(!toolbar.isVisible && toolbar.prefersPointerLock)
        toolbar.setRemoteButtonHeld(true) // a press with the locked pointer never unlocks it
        #expect(toolbar.prefersPointerLock)
        toolbar.toggle()                  // shown while that button is held
        #expect(!toolbar.prefersPointerLock)
        toolbar.toggle()                  // hidden again before the release
        #expect(!toolbar.prefersPointerLock)
        toolbar.setRemoteButtonHeld(false)
        #expect(toolbar.prefersPointerLock)
        toolbar.toggle()
        toolbar.setRemoteButtonHeld(true) // a desktop press with the local pointer
        toolbar.remoteInteraction()       // dismisses the toolbar…
        #expect(!toolbar.isVisible && !toolbar.prefersPointerLock) // …but the drag keeps that pointer
        toolbar.setRemoteButtonHeld(false)
        #expect(toolbar.prefersPointerLock)
        for _ in 0..<9 { toolbar.toggle() }
        #expect(toolbar.isVisible && !toolbar.prefersPointerLock)
        toolbar.sessionEnded()
        #expect(!toolbar.prefersPointerLock) // ended: the session-ended Close is clickable
    }
}

@Suite("Toolbar gesture hint")
@MainActor
struct ToolbarHintTests {
    @Test func shownOnFirstEstablishmentOnlyAndDismissedAutomatically() throws {
        let timers = ManualSchedule(), store = TestDefaults()
        defer { store.remove() }
        let toolbar = makeToolbar(timers, defaults: store.defaults)
        #expect(!toolbar.showsHint && !store.defaults.bool(forKey: SessionToolbar.hintShownKey))
        toolbar.sessionEstablished(offeringHint: true)
        #expect(toolbar.showsHint && store.defaults.bool(forKey: SessionToolbar.hintShownKey))
        let hint = try #require(timers.live.first { $0.delay == SessionToolbar.hintDuration })
        timers.fire(hint)
        #expect(!toolbar.showsHint && toolbar.isVisible) // the toolbar keeps its own timeout
    }

    @Test func neverRepeatedInLaterSessionsOrLaunches() {
        let store = TestDefaults()
        defer { store.remove() }
        makeToolbar(ManualSchedule(), defaults: store.defaults).sessionEstablished(offeringHint: true)
        let nextSession = makeToolbar(ManualSchedule(), defaults: store.defaults)
        nextSession.sessionEstablished(offeringHint: true)
        #expect(!nextSession.showsHint)
        // A new launch reads the persisted domain through a fresh defaults object.
        let relaunched = makeToolbar(ManualSchedule(), defaults: UserDefaults(suiteName: store.suite)!)
        relaunched.sessionEstablished(offeringHint: true)
        #expect(!relaunched.showsHint)
    }

    @Test func notOfferedWithoutALiveConnectionAndEndedByTheGesture() {
        let store = TestDefaults()
        defer { store.remove() }
        let replay = makeToolbar(ManualSchedule(), defaults: store.defaults)
        replay.sessionEstablished(offeringHint: false)
        #expect(!replay.showsHint && !store.defaults.bool(forKey: SessionToolbar.hintShownKey))
        let timers = ManualSchedule(), live = makeToolbar(timers, defaults: store.defaults)
        live.sessionEstablished(offeringHint: true)
        live.toggle()
        #expect(!live.showsHint && !live.isVisible && timers.live.isEmpty)
    }
}

@Suite("Toolbar gesture, keyboard forwarding and accessibility")
@MainActor
struct ToolbarInputArbitrationTests {
    private func taps(_ view: DesktopView) -> [UITapGestureRecognizer] {
        view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
    }

    private func recordingView() -> (DesktopView, () -> [ViewInput], () -> Int) {
        let view = DesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var inputs: [ViewInput] = [], toggles = 0
        view.onInput = { inputs.append($0) }
        view.onToolbarToggle = { toggles += 1 }
        return (view, { inputs }, { toggles })
    }

    @Test func twoFingerDoubleTapIsDirectTouchOnlyAndRightClickWaitsForIt() throws {
        let view = DesktopView(frame: .zero)
        let toggle = try #require(taps(view).first { $0.numberOfTouchesRequired == 2 && $0.numberOfTapsRequired == 2 })
        let right = try #require(taps(view).first { $0.numberOfTouchesRequired == 2 && $0.numberOfTapsRequired == 1 })
        let click = try #require(taps(view).first { $0.numberOfTouchesRequired == 1 && $0.numberOfTapsRequired == 1 })
        #expect(toggle.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)]) // no Pencil, mouse or trackpad
        #expect(toggle.delegate === view && right.delegate === view)
        #expect(view.gestureRecognizer(right, shouldRequireFailureOf: toggle))
        #expect(!view.gestureRecognizer(toggle, shouldRequireFailureOf: right))
        #expect(!view.gestureRecognizer(click, shouldRequireFailureOf: toggle))
        #expect(!view.gestureRecognizer(toggle, shouldRecognizeSimultaneouslyWith: right))
        #expect(taps(view).count == 3)
    }

    @Test func toggleGestureIsLocalInEveryModeAndIgnoresUnfinishedStates() {
        let (view, inputs, toggles) = recordingView()
        let tap = TapSample()
        for state in [UIGestureRecognizer.State.possible, .began, .changed, .cancelled, .failed] {
            tap.send(to: view, "toolbarToggled:", state)
        }
        #expect(toggles() == 0)
        tap.send(to: view, "toolbarToggled:")
        view.panEnabled = true // local pan suppresses remote pointing, not the local toggle
        tap.send(to: view, "toolbarToggled:")
        view.panEnabled = false
        view.trackpad = false
        tap.send(to: view, "toolbarToggled:")
        #expect(toggles() == 3)
        // Only the mode switches' existing releases: the toggle itself emits nothing.
        #expect(inputs().allSatisfy { if case .release = $0 { true } else { false } } && inputs().count == 3)
    }

    @Test func singleAndTwoFingerTapsKeepTheirClicks() {
        let (view, inputs, toggles) = recordingView()
        let tap = TapSample()
        tap.send(to: view, "tapped:")
        tap.send(to: view, "rightTapped:")
        tap.send(to: view, "rightTapped:", .cancelled)
        tap.send(to: view, "rightTapped:", .failed)
        #expect(toggles() == 0)
        let clicks = inputs().compactMap { if case .click(let p, let mask, let relative) = $0 { (p, mask, relative) } else { nil } }
        #expect(clicks.map(\.1) == [1, 4] && clicks.allSatisfy { $0.0 == tap.point && $0.2 })
    }

    private func keys(_ inputs: [ViewInput]) -> [String] {
        inputs.compactMap { if case .key(let k, let down) = $0 { "\(k)\(down ? "↓" : "↑")" } else { nil } }
    }

    /// No local keyboard shortcut (deliberate product decision): every physical
    /// key, Command-Shift-T included, reaches the Mac exactly as pressed.
    @Test func commandShiftTReachesTheMacUnchangedInAnyOrder() {
        let (view, inputs, toggles) = recordingView()
        view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
        view.keyDown(.keyboardLeftShift, symbol: 0xffe1)
        view.keyDown(.keyboardT, symbol: 0x74)
        view.keyUp(.keyboardT); view.keyUp(.keyboardLeftShift); view.keyUp(.keyboardLeftGUI)
        view.keyDown(.keyboardRightShift, symbol: 0xffe2) // other press and release orders
        view.keyDown(.keyboardRightGUI, symbol: 0xffec)
        view.keyDown(.keyboardT, symbol: 0x74)
        view.keyUp(.keyboardRightGUI); view.keyUp(.keyboardT); view.keyUp(.keyboardRightShift)
        #expect(toggles() == 0)
        #expect(keys(inputs()) == ["65515↓", "65505↓", "116↓", "116↑", "65505↑", "65515↑",
                                   "65506↓", "65516↓", "116↓", "65516↑", "116↑", "65506↑"])
    }

    @Test func otherShortcutsModifiersAndTheReleaseBarrierAreUnchanged() {
        let (view, inputs, toggles) = recordingView()
        let chords: [[(UIKeyboardHIDUsage, UInt32)]] = [
            [(.keyboardLeftGUI, 0xffeb), (.keyboardT, 0x74)],                              // ⌘T
            [(.keyboardLeftGUI, 0xffeb), (.keyboardLeftShift, 0xffe1), (.keyboardU, 0x75)], // ⌘⇧U
            [(.keyboardLeftShift, 0xffe1), (.keyboardT, 0x54)],                            // ⇧T
            [(.keyboardLeftGUI, 0xffeb)],                                                  // Command alone
        ]
        var expected: [String] = []
        for chord in chords {
            for (code, symbol) in chord { view.keyDown(code, symbol: symbol); expected.append("\(symbol)↓") }
            for (code, symbol) in chord.reversed() { view.keyUp(code); expected.append("\(symbol)↑") }
        }
        view.keyDown(.keyboardLeftAlt, symbol: nil) // no keysym: nothing is sent, so no release either
        view.keyUp(.keyboardLeftAlt)
        #expect(toggles() == 0 && keys(inputs()) == expected)
        // Modifier-assisted pointing: Command stays held around the click.
        let before = inputs().count
        view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
        TapSample().send(to: view, "tapped:")
        view.keyUp(.keyboardLeftGUI)
        let around = inputs().dropFirst(before).map { input -> String in
            switch input {
            case .key(let k, let down): "\(k)\(down ? "↓" : "↑")"
            case .click(_, let mask, _): "click\(mask)"
            default: "other"
            }
        }
        #expect(around == ["65515↓", "click1", "65515↑"])
        // Focus loss still releases held keys once, and their later key-up is not resent.
        view.keyDown(.keyboardLeftShift, symbol: 0xffe1)
        view.cancelInput()
        view.keyUp(.keyboardLeftShift)
        #expect(keys(Array(inputs().suffix(2))) == ["65505↓"])
        #expect(inputs().last.map { if case .release = $0 { true } else { false } } == true)
    }

    @Test func intentionalRemoteActionsAreClassified() {
        let p = CGPoint(x: 1, y: 2)
        let dismissing: [ViewInput] = [.click(p, 1, true), .click(p, 4, false), .button(p, 1, false), .button(.zero, 2, true),
                                       .wheel(8, 3), .key(0x61, true), .key(0xff0d, true), .key(0xff1b, true)]
        let passive: [ViewInput] = [.absolute(p), .relative(p), .button(p, 0, false), .release, .pointerRelease,
                                    .key(0x61, false), .key(0xffe1, true), .key(0xffe3, true), .key(0xffe9, true),
                                    .key(0xffeb, true), .key(0xffec, true)]
        #expect(dismissing.allSatisfy { $0.isIntentionalRemoteAction })
        #expect(!passive.contains { $0.isIntentionalRemoteAction })
    }

    /// A pointer-lock handover (toolbar hide/show) drops local pointer
    /// state and releases remotely held buttons, but never touches physically
    /// held keys — their key-up is still to come, including across rapid,
    /// asynchronously delivered transitions. Genuine focus loss keeps the full
    /// barrier. The production notification entries run through the same
    /// target/action path as the gesture tests (no global broadcast: other
    /// suites run in parallel in this process).
    @Test func pointerLockHandoverPreservesHeldKeys() {
        let (view, inputs, toggles) = recordingView()
        func kinds(_ list: [ViewInput]) -> [String] {
            list.map { input in
                switch input {
                case .key(let k, let down): "key\(k)\(down ? "↓" : "↑")"
                case .release: "release"
                case .pointerRelease: "pointerRelease"
                default: "other"
                }
            }
        }
        view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
        view.keyDown(.keyboardA, symbol: 0x61)
        _ = view.perform(NSSelectorFromString("pointerLockChanged")) // lock acquired: the toolbar auto-hid
        view.keyUp(.keyboardA); view.keyUp(.keyboardLeftGUI)
        #expect(kinds(inputs()) == ["key65515↓", "key97↓", "pointerRelease", "key97↑", "key65515↑"])
        #expect(toggles() == 0)
        // Rapid duplicate deliveries leave the held keys alone as well.
        let base = inputs().count
        view.keyDown(.keyboardLeftGUI, symbol: 0xffeb)
        for _ in 0..<5 { _ = view.perform(NSSelectorFromString("pointerLockChanged")) }
        view.keyUp(.keyboardLeftGUI)
        #expect(kinds(Array(inputs().dropFirst(base)))
            == ["key65515↓", "pointerRelease", "pointerRelease", "pointerRelease", "pointerRelease", "pointerRelease", "key65515↑"])
        // Genuine focus loss still releases everything once.
        view.keyDown(.keyboardLeftShift, symbol: 0xffe1)
        _ = view.perform(NSSelectorFromString("focusLost"))
        view.keyUp(.keyboardLeftShift) // forgotten locally: sends nothing
        #expect(kinds(Array(inputs().suffix(2))) == ["key65505↓", "release"])
        #expect(toggles() == 0)
    }

    @Test func accessibilityElementOffersALocalToggleAndNeverClicksTheMac() throws {
        let (view, inputs, toggles) = recordingView()
        #expect(view.isAccessibilityElement && view.accessibilityLabel == "Remote Mac desktop")
        #expect(view.accessibilityHint == "Shows or hides the session toolbar.")
        view.toolbarVisible = true
        let hide = try #require(view.accessibilityCustomActions?.first)
        #expect(hide.name == "Hide session toolbar" && view.accessibilityCustomActions?.count == 1)
        #expect(hide.actionHandler?(hide) == true)
        view.toolbarVisible = false
        #expect(view.accessibilityCustomActions?.first?.name == "Show session toolbar")
        #expect(view.accessibilityPerformMagicTap())
        #expect(view.accessibilityActivate())
        #expect(toggles() == 3 && inputs().isEmpty)
        view.onToolbarToggle = nil
        #expect(view.accessibilityActivate() && inputs().isEmpty) // no synthesized tap even when unbound
        #expect(!view.accessibilityPerformMagicTap())
    }
}

@Suite("Toolbar controls")
@MainActor
struct ToolbarControlTests {
    /// The production control and its UIKit control events (touch, mouse and
    /// trackpad all arrive as these events).
    @Test func actionButtonPressSuspendsDismissalThroughItsControlEvents() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let button = SessionActionButton(toolbar: toolbar)
        var actions = 0
        button.action = { actions += 1 }
        #expect(button.configuration != nil && button.isPointerInteractionEnabled && button.toolbar === toolbar)
        let deadline = try #require(timers.live.first)
        button.sendActions(for: .touchDown) // pressed just before the timeout
        #expect(toolbar.isControlPressed && deadline.cancelled && timers.live.isEmpty)
        timers.fire(deadline)               // held beyond the original deadline
        #expect(toolbar.isVisible && actions == 0)
        button.sendActions(for: .touchUpInside) // UIButton turns this into its primary action
        #expect(actions == 1)
        #expect(!toolbar.isControlPressed && toolbar.isVisible)
        #expect(timers.live.count == 1 && timers.live.first?.delay == .seconds(5))
        button.sendActions(for: .touchDown) // cancelled: no action, timeout restarted
        button.sendActions(for: .touchCancel)
        button.sendActions(for: .touchDown) // dragged off and released outside
        button.sendActions(for: .touchUpOutside)
        #expect(actions == 1)
        #expect(!toolbar.isControlPressed && timers.live.count == 1)
        button.sendActions(for: .primaryActionTriggered) // VoiceOver or keyboard activation: no press phase
        #expect(actions == 2)
        #expect(!toolbar.isControlPressed && timers.live.count == 1)
        button.frame = CGRect(x: 0, y: 0, width: 60, height: 30)
        #expect(button.point(inside: CGPoint(x: 30, y: 15), with: nil))
        toolbar.toggle() // hidden: even a control still on screen during the animation lets touches through
        #expect(!button.point(inside: CGPoint(x: 30, y: 15), with: nil))
    }

    @Test func controlRemovedDuringAPressLeavesNoStaleSuspension() throws {
        let timers = ManualSchedule(), toolbar = makeToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let button = SessionActionButton(toolbar: toolbar)
        window.addSubview(button)
        button.sendActions(for: .touchDown)
        #expect(toolbar.isControlPressed && timers.live.isEmpty)
        button.removeFromSuperview() // left the window without a touch-up
        #expect(!toolbar.isControlPressed && timers.live.count == 1)
    }

    @Test func menuButtonPressAndMenuAreProtectedTogether() throws {
        let timers = ManualSchedule()
        let controller = SessionController(toolbar: makeToolbar(timers))
        controller.toolbar.sessionEstablished(offeringHint: false)
        let button = SessionMenuControl(controller: controller)
        let interaction = try #require(button.contextMenuInteraction)
        button.sendActions(for: .touchDown)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: UIContextMenuConfiguration(), animator: nil)
        button.sendActions(for: .touchCancel) // the menu takes over the touch
        #expect(controller.toolbar.isMenuOpen && !controller.toolbar.isControlPressed && timers.live.isEmpty)
        button.contextMenuInteraction(interaction, willEndFor: UIContextMenuConfiguration(), animator: nil)
        #expect(!controller.toolbar.isMenuOpen && timers.live.count == 1)
    }

    @Test func menuPresentationSuspendsDismissalAndItemsMirrorTheController() throws {
        let timers = ManualSchedule()
        let controller = SessionController(toolbar: makeToolbar(timers))
        controller.toolbar.sessionEstablished(offeringHint: false)
        let button = SessionMenuControl(controller: controller)
        #expect(button.configuration?.title == "Retina" && button.showsMenuAsPrimaryAction)
        let interaction = try #require(button.contextMenuInteraction)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: UIContextMenuConfiguration(), animator: nil)
        #expect(controller.toolbar.isMenuOpen && timers.live.isEmpty)
        button.contextMenuInteraction(interaction, willEndFor: UIContextMenuConfiguration(), animator: nil)
        #expect(!controller.toolbar.isMenuOpen && timers.live.count == 1)

        let menu = try #require(button.menu)
        button.refresh()
        #expect(button.menu === menu) // an unrelated update keeps the (possibly open) menu
        let items = menu.children
        #expect(items.map(\.title) == ["Retina", "More Space", "Local pan (one finger)", "Input", "Keyboard"])
        let input = try #require(items[3] as? UIMenu)
        #expect(input.options.contains(.singleSelection) && input.subtitle == "Trackpad")
        #expect((input.children as? [UIAction])?.map(\.state) == [.on, .off])
        #expect((items[2] as? UIAction)?.state == .off && (items[4] as? UIAction)?.state == .off)
        controller.panEnabled = true; controller.trackpad = false; controller.keyboardShown = true
        controller.setProfile(.moreSpace)
        button.refresh()
        let updated = try #require(button.menu?.children)
        #expect(button.configuration?.title == "More Space" && (updated[3] as? UIMenu)?.subtitle == "Direct")
        #expect(((updated[3] as? UIMenu)?.children as? [UIAction])?.map(\.state) == [.off, .on])
        #expect((updated[2] as? UIAction)?.state == .on && (updated[4] as? UIAction)?.state == .on)
    }
}

/// The real SwiftUI session view in a window: toolbar visibility changes the
/// overlay only. The desktop view, its Metal layer and drawable stay as they were.
@Suite("Toolbar rendering invariants", .serialized)
@MainActor
struct ToolbarRenderingInvariantTests {
    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    private func settle(_ window: UIWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return condition()
    }

    /// Also exercises the real Fit button across the auto-hide deadline
    /// and the pointer-lock request wiring of the session host.
    @Test(arguments: [CGSize(width: 912, height: 420), CGSize(width: 420, height: 912), CGSize(width: 1194, height: 834)])
    func toolbarTransitionsKeepSurfaceGeometryAndHandOverThePointer(_ size: CGSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeToolbar(timers))
        var preferences: [Bool] = []
        weak var hostRef: SessionHostingController?
        let host = SessionHostingController(rootView: SessionView(
            source: SessionSource(id: "toolbar-invariants", clipURL: nil), controller: controller, onClose: {},
            onPointerLockPreference: { preferences.append($0); hostRef?.pointerLockRequested = $0 }))
        hostRef = host
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        // `updateUIView` queues the start; a replay source is established at start.
        try #require(await settle(window) {
            find(SessionMenuControl.self, in: host.view)?.window != nil && controller.toolbar.stage == .established
        })
        let desktop = try #require(find(DesktopView.self, in: host.view))
        let layer = desktop.metalLayer
        let frame = desktop.convert(desktop.bounds, to: window), drawable = layer.drawableSize
        let menu = try #require(find(SessionMenuControl.self, in: host.view))
        let menuCenter = menu.convert(CGPoint(x: menu.bounds.midX, y: menu.bounds.midY), to: window)
        #expect(desktop.toolbarVisible && frame == window.bounds && drawable.width > 0)
        #expect(window.hitTest(menuCenter, with: nil)?.isDescendant(of: menu) == true) // a click reaches the control
        #expect(preferences == [false] && !host.prefersPointerLocked)

        func expectSurfaceUnchanged() {
            #expect(find(DesktopView.self, in: host.view) === desktop && desktop.metalLayer === layer)
            let current: CGRect = desktop.convert(desktop.bounds, to: window)
            #expect(current == frame)
            #expect(layer.drawableSize == drawable)
        }

        // A press on the real Fit button that outlasts the deadline, then succeeds.
        var buttons: [SessionActionButton] = []
        func collect(_ view: UIView) {
            if let button = view as? SessionActionButton { buttons.append(button) }
            view.subviews.forEach(collect)
        }
        collect(host.view)
        #expect(buttons.compactMap { $0.configuration?.title } == ["Fit", "Close"])
        let fit = try #require(buttons.first { $0.configuration?.title == "Fit" })
        let renderer = try #require(controller.renderer)
        renderer.zoom = 2
        let deadline = try #require(timers.live.first)
        fit.sendActions(for: .touchDown)
        timers.fire(deadline)
        try #require(await settle(window) { desktop.toolbarVisible })
        fit.sendActions(for: .touchUpInside) // UIButton turns this into its primary action
        #expect(renderer.zoom == 1 && !controller.toolbar.isControlPressed && timers.live.count == 1)

        func settled(visible: Bool) async throws {
            try #require(await settle(window) {
                desktop.toolbarVisible == visible && (find(SessionMenuControl.self, in: host.view) != nil) == visible
            })
            expectSurfaceUnchanged()
            #expect(host.prefersPointerLocked == !visible)
        }
        timers.fire(try #require(timers.live.first)) // automatic dismissal
        try await settled(visible: false)
        desktop.onToolbarToggle?()
        try await settled(visible: true)
        desktop.onToolbarToggle?()
        try await settled(visible: false)
        #expect(preferences == [false, true, false, true])
        // Hidden: nothing of the toolbar is left to intercept the touch or click.
        #expect(window.hitTest(menuCenter, with: nil) === desktop)
    }
}
