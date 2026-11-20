// Vicinia tests — radial immersive controls: placement, safe areas,
// orientation/size adaptation, common-ancestor gesture coordination,
// outside-tap local dismissal without blocking remote desktop gestures,
// two-finger double-tap over radial controls, inactivity timeout suppression,
// pointer-lock handover, accessibility, Release HUD/Esc absence, and Escape
// key preservation.
// SPDX-License-Identifier: MIT

import Foundation
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Vicinia

@MainActor
private final class SafeAreaTestWindow: UIWindow {
    var customSafeAreaInsets: UIEdgeInsets
    init(windowScene: UIWindowScene, frame: CGRect, safeAreaInsets: UIEdgeInsets) {
        self.customSafeAreaInsets = safeAreaInsets
        super.init(windowScene: windowScene)
        self.frame = frame
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var safeAreaInsets: UIEdgeInsets { customSafeAreaInsets }
}

/// Deterministic `UITouch` sample for driving real UIKit delegate / touch paths.
@MainActor
private final class TouchSample: UITouch {
    private weak var sampleView: UIView?
    private let samplePoint: CGPoint
    private let sampleType: UITouch.TouchType
    private let samplePhase: UITouch.Phase

    init(view: UIView?, pointInView: CGPoint, type: UITouch.TouchType = .direct, phase: UITouch.Phase = .began) {
        self.sampleView = view
        self.samplePoint = pointInView
        self.sampleType = type
        self.samplePhase = phase
        super.init()
    }

    override var view: UIView? { sampleView }
    override var type: UITouch.TouchType { sampleType }
    override var phase: UITouch.Phase { samplePhase }

    override func location(in target: UIView?) -> CGPoint {
        guard let sampleView else { return samplePoint }
        guard let target else { return sampleView.convert(samplePoint, to: nil) }
        return sampleView.convert(samplePoint, to: target)
    }
}

/// Deterministic `UIEvent` carrying explicit touches for multi-touch verification.
@MainActor
private final class TouchEventSample: UIEvent {
    private let sampleTouches: Set<UITouch>
    init(touches: Set<UITouch>) {
        self.sampleTouches = touches
        super.init()
    }
    override var allTouches: Set<UITouch>? { sampleTouches }
}

@MainActor
private final class PanGestureSample: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .changed
    var delta = CGPoint(x: 24, y: 18)
    var fingers = 1
    var point = CGPoint(x: 120, y: 200)
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override var numberOfTouches: Int { fingers }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { delta }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { delta = translation }
}

@MainActor
private func makeRadialToolbar(
    _ schedule: ManualSchedule,
    defaults: UserDefaults = TestDefaults().defaults,
    assistive: @escaping @MainActor () -> Bool = { false }
) -> SessionToolbar {
    SessionToolbar(defaults: defaults, assistiveTechnologyRunning: assistive, schedule: schedule.schedule)
}

@MainActor
private func findViews<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
    var result: [T] = []
    if let match = root as? T { result.append(match) }
    for subview in root.subviews {
        result.append(contentsOf: findViews(type, in: subview))
    }
    return result
}

@MainActor
private func settleWindow(_ window: UIWindow, until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
        window.layoutIfNeeded()
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    } while ContinuousClock.now < deadline
    return condition()
}

/// Drives a recognizer's own target/action cleanly through a subclassed state override.
@MainActor
private func fireTapRecognizer(_ recognizer: UITapGestureRecognizer,
                               on target: AnyObject,
                               selector: String,
                               at pointInView: CGPoint = .zero,
                               state: UIGestureRecognizer.State = .ended) {
    let sample = TapSample()
    sample.sampleState = state
    sample.point = pointInView
    _ = target.perform(NSSelectorFromString(selector), with: sample)
}

@Suite("Radial menu layout and placement")
struct RadialMenuLayoutTests {
    @Test func diameterTargets180To220AndAdaptsToAvailableSpace() {
        let iPhoneLandscape = RadialMenuLayout(
            containerSize: CGSize(width: 912, height: 420),
            safeAreaInsets: EdgeInsets(top: 0, leading: 68, bottom: 20, trailing: 68),
            anchor: CGPoint(x: 456, y: 210)
        )
        #expect((180...220).contains(iPhoneLandscape.diameter))
        #expect(iPhoneLandscape.hubDiameter >= 44 && iPhoneLandscape.itemDiameter >= 44)
        #expect(iPhoneLandscape.center == CGPoint(x: 456, y: 210))

        let iPadLandscape = RadialMenuLayout(
            containerSize: CGSize(width: 1194, height: 834),
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            anchor: CGPoint(x: 600, y: 420)
        )
        #expect((180...220).contains(iPadLandscape.diameter))
        #expect(iPadLandscape.center == CGPoint(x: 600, y: 420))

        let accessibility = RadialMenuLayout(
            containerSize: CGSize(width: 420, height: 912),
            safeAreaInsets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
            anchor: CGPoint(x: 210, y: 450),
            isAccessibilityTextSize: true
        )
        #expect((180...220).contains(accessibility.diameter))
        #expect(accessibility.diameter >= iPhoneLandscape.diameter)

        // Tight container adapts smoothly without dropping below 44x44 targets.
        let compact = RadialMenuLayout(
            containerSize: CGSize(width: 212, height: 212),
            safeAreaInsets: EdgeInsets(),
            anchor: CGPoint(x: 106, y: 106)
        )
        #expect(compact.diameter == 188)
        #expect(compact.hubDiameter >= 44 && compact.itemDiameter >= 44)

        let extreme = RadialMenuLayout(
            containerSize: CGSize(width: 160, height: 160),
            safeAreaInsets: EdgeInsets(),
            anchor: CGPoint(x: 80, y: 80)
        )
        #expect(extreme.hubDiameter >= 44 && extreme.itemDiameter >= 44)
        #expect(extreme.diameter <= 160)
    }

    @Test func radialCommandsAreNonOverlappingAndContainedWithinMenuCircle() {
        for (size, isAX) in [
            (CGSize(width: 912, height: 420), false),
            (CGSize(width: 420, height: 912), true),
            (CGSize(width: 1194, height: 834), false),
            (CGSize(width: 160, height: 160), false),
        ] {
            let layout = RadialMenuLayout(
                containerSize: size,
                safeAreaInsets: EdgeInsets(),
                anchor: CGPoint(x: size.width / 2, y: size.height / 2),
                isAccessibilityTextSize: isAX
            )
            #expect(layout.hubDiameter >= 44 && layout.itemDiameter >= 44)
            let commands = RadialMenuLayout.Command.allCases
            #expect(commands.count == 3)
            for command in commands {
                let c = layout.center(for: command)
                let distFromHub = hypot(c.x - layout.center.x, c.y - layout.center.y)
                #expect(distFromHub >= (layout.hubDiameter + layout.itemDiameter) / 2 + 3.9)
                #expect(distFromHub + layout.itemDiameter / 2 <= layout.radius + 0.5)
            }
            for i in 0..<commands.count {
                for j in (i + 1)..<commands.count {
                    let a = layout.center(for: commands[i]), b = layout.center(for: commands[j])
                    let separation = hypot(a.x - b.x, a.y - b.y)
                    #expect(separation > layout.itemDiameter + 20)
                }
            }
        }
    }

    @Test func clampsEdgeAndCornerAnchorsInsideSafeAreasInPortraitAndLandscape() {
        let cases: [(CGSize, EdgeInsets)] = [
            (CGSize(width: 912, height: 420), EdgeInsets(top: 0, leading: 68, bottom: 20, trailing: 68)),   // iPhone landscape
            (CGSize(width: 420, height: 912), EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),   // iPhone portrait
            (CGSize(width: 1194, height: 834), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),  // iPad landscape
            (CGSize(width: 834, height: 1194), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),  // iPad portrait
        ]
        for (size, insets) in cases {
            let safeRect = CGRect(
                x: insets.leading, y: insets.top,
                width: size.width - insets.leading - insets.trailing,
                height: size.height - insets.top - insets.bottom
            )
            let anchors: [CGPoint?] = [
                nil,
                CGPoint(x: 0, y: 0),
                CGPoint(x: size.width, y: 0),
                CGPoint(x: 0, y: size.height),
                CGPoint(x: size.width, y: size.height),
                CGPoint(x: -40, y: size.height / 2),
                CGPoint(x: size.width + 40, y: size.height / 2),
            ]
            for anchor in anchors {
                let layout = RadialMenuLayout(containerSize: size, safeAreaInsets: insets, anchor: anchor)
                #expect(safeRect.contains(layout.menuFrame))
                #expect(layout.menuFrame.minX >= safeRect.minX + RadialMenuLayout.edgeMargin - 0.5)
                #expect(layout.menuFrame.maxX <= safeRect.maxX - RadialMenuLayout.edgeMargin + 0.5)
                #expect(layout.menuFrame.minY >= safeRect.minY + RadialMenuLayout.edgeMargin - 0.5)
                #expect(layout.menuFrame.maxY <= safeRect.maxY - RadialMenuLayout.edgeMargin + 0.5)
            }
        }
    }

    @Test func orientationRotationReclampsPreviouslyAnchoredMenuInsideNewSafeArea() {
        let landscapeAnchor = CGPoint(x: 820, y: 200)
        let landscape = RadialMenuLayout(
            containerSize: CGSize(width: 912, height: 420),
            safeAreaInsets: EdgeInsets(top: 0, leading: 68, bottom: 20, trailing: 68),
            anchor: landscapeAnchor
        )
        #expect(landscape.safeRect.contains(landscape.menuFrame))

        // Rotate to portrait keeping the same activation anchor: menu reclamps cleanly inside portrait safe rect.
        let portrait = RadialMenuLayout(
            containerSize: CGSize(width: 420, height: 912),
            safeAreaInsets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
            anchor: landscapeAnchor
        )
        #expect(portrait.safeRect.contains(portrait.menuFrame))
        #expect(portrait.center.x <= 420 - RadialMenuLayout.edgeMargin - portrait.radius + 0.5)
    }
}

@Suite("Radial toolbar state and dismissal")
@MainActor
struct RadialToolbarStateTests {
    @Test func toggleRecordsActivationPointAndPreservesItDuringHideTransition() throws {
        let timers = ManualSchedule(), toolbar = makeRadialToolbar(timers)
        #expect(toolbar.anchorPoint == nil && !toolbar.canDismiss)
        toolbar.dismiss() // pinned while pending
        #expect(toolbar.isVisible)

        toolbar.sessionEstablished(offeringHint: false)
        #expect(toolbar.canDismiss && toolbar.anchorPoint == nil)
        toolbar.dismiss()
        #expect(!toolbar.isVisible && !toolbar.canDismiss && timers.live.isEmpty)

        let firstPoint = CGPoint(x: 240, y: 180)
        toolbar.toggle(at: firstPoint)
        #expect(toolbar.isVisible && toolbar.anchorPoint == firstPoint && timers.live.count == 1)

        // Hiding keeps the last anchor so exit animation stays in place.
        toolbar.dismiss()
        #expect(!toolbar.isVisible && toolbar.anchorPoint == firstPoint && timers.live.isEmpty)

        // Re-opening without an anchor (e.g. VoiceOver) returns to default placement.
        toolbar.toggle()
        #expect(toolbar.isVisible && toolbar.anchorPoint == nil)

        // Ending the session pins Close and resets anchor.
        toolbar.toggle(at: firstPoint)
        toolbar.sessionEnded()
        #expect(toolbar.isVisible && !toolbar.canDismiss && toolbar.anchorPoint == nil)
        toolbar.dismiss()
        #expect(toolbar.isVisible) // Close stays reachable after session ends
    }

    @Test func dismissWorksWithAssistiveTechnologyAndClearsHintAndTimers() {
        @MainActor final class Flag { var active = true }
        let assistive = Flag()
        let timers = ManualSchedule(), store = TestDefaults()
        defer { store.remove() }
        let toolbar = makeRadialToolbar(timers, defaults: store.defaults, assistive: { assistive.active })
        toolbar.sessionEstablished(offeringHint: true)
        #expect(toolbar.isVisible && toolbar.showsHint && timers.live.count == 1) // hint only; no auto-hide
        toolbar.dismiss()
        #expect(!toolbar.isVisible && !toolbar.showsHint && timers.live.isEmpty)
        assistive.active = false
        toolbar.toggle(at: CGPoint(x: 300, y: 200))
        #expect(toolbar.isVisible && timers.live.count == 1 && timers.live.first?.delay == .seconds(5))
    }

    @Test func centerDismissButtonPressSuspendsTimeoutAndTapDismissesLocally() throws {
        let timers = ManualSchedule(), toolbar = makeRadialToolbar(timers)
        toolbar.sessionEstablished(offeringHint: false)
        let dismissButton = SessionDismissButton(toolbar: toolbar)
        dismissButton.onDismiss = { toolbar.dismiss() }
        #expect(dismissButton.accessibilityLabel == "Dismiss session controls")
        #expect(dismissButton.accessibilityIdentifier == "radial.dismiss")
        #expect(dismissButton.showsLargeContentViewer)

        let deadline = try #require(timers.live.first)
        dismissButton.sendActions(for: .touchDown)
        #expect(toolbar.isControlPressed && deadline.cancelled && timers.live.isEmpty)
        timers.fire(deadline)
        #expect(toolbar.isVisible)

        // Dragging off cancels press and restarts timeout without dismissing.
        dismissButton.sendActions(for: .touchUpOutside)
        #expect(!toolbar.isControlPressed && toolbar.isVisible && timers.live.count == 1)

        // Tapping center dismisses immediately with no lingering timers.
        dismissButton.sendActions(for: .touchDown)
        dismissButton.sendActions(for: .touchUpInside)
        #expect(!toolbar.isVisible && !toolbar.isControlPressed && timers.live.isEmpty)
    }

    @Test func desktopGestureReportsActivationPointWithoutForwardingRemoteInput() throws {
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeRadialToolbar(timers))
        let view = DesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        controller.attach(view)
        defer { controller.stop() }
        controller.toolbar.sessionEstablished(offeringHint: false)
        controller.toolbar.dismiss()

        var remoteEvents: [ViewInput] = []
        let originalOnInput = view.onInput
        view.onInput = { event in remoteEvents.append(event); originalOnInput?(event) }

        let tap = TapSample()
        tap.point = CGPoint(x: 310, y: 175)
        tap.send(to: view, "toolbarToggled:")
        #expect(controller.toolbar.isVisible)
        #expect(controller.toolbar.anchorPoint == CGPoint(x: 310, y: 175))
        #expect(remoteEvents.isEmpty)

        tap.send(to: view, "toolbarToggled:")
        #expect(!controller.toolbar.isVisible)
        #expect(remoteEvents.isEmpty)
    }

    /// Regression for Finding R2: two-finger touch events over radial buttons
    /// must never trigger Fit, Close, Dismiss, or open Retina's menu, while
    /// single-finger touches continue activating commands normally.
    @Test func multiTouchOverRadialControlsNeverActivatesCommandsAndSingleTapStillWorks() throws {
        let timers = ManualSchedule()
        let controller = SessionController(toolbar: makeRadialToolbar(timers))
        controller.toolbar.sessionEstablished(offeringHint: false)
        let layout = RadialMenuLayout(
            containerSize: CGSize(width: 800, height: 400),
            safeAreaInsets: EdgeInsets(),
            anchor: CGPoint(x: 400, y: 200)
        )
        var closes = 0
        let container = RadialMenuContainerView(controller: controller, layout: layout) { closes += 1 }
        container.layoutIfNeeded()
        var fits = 0
        container.fitButton.action = { fits += 1 }

        // Every radial control enables multi-touch so two fingers landing on
        // the same button are both forwarded to the ancestor toggle recognizer.
        for control in container.controls {
            #expect(control.isMultipleTouchEnabled)
        }

        // Simulate a two-finger direct touch touching down and lifting over each control.
        let twoFingerButtons: [SessionToolbarControl] = [
            container.fitButton, container.closeButton, container.dismissButton, container.menuButton
        ]
        for button in twoFingerButtons {
            let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
            let t1 = TouchSample(view: button, pointInView: center, type: .direct, phase: .began)
            let t2 = TouchSample(view: container, pointInView: CGPoint(x: 20, y: 20), type: .direct, phase: .began)
            let beganEvent = TouchEventSample(touches: [t1, t2])
            button.touchesBegan([t1], with: beganEvent)
            #expect(button.sawMultiTouch && !controller.toolbar.isControlPressed)
            if let menuButton = button as? SessionMenuControl, let interaction = menuButton.contextMenuInteraction {
                #expect(menuButton.contextMenuInteraction(interaction, configurationForMenuAtLocation: center) == nil)
            }
            let e1 = TouchSample(view: button, pointInView: center, type: .direct, phase: .ended)
            let e2 = TouchSample(view: container, pointInView: CGPoint(x: 20, y: 20), type: .direct, phase: .ended)
            button.touchesEnded([e1], with: TouchEventSample(touches: [e1, e2]))
        }
        #expect(fits == 0 && closes == 0 && controller.toolbar.isVisible)

        // Single-finger primary activation still works for Fit, Close, Dismiss, and Retina.
        container.fitButton.sendActions(for: .touchDown)
        container.fitButton.sendActions(for: .touchUpInside)
        #expect(fits == 1 && controller.toolbar.isVisible)

        container.closeButton.sendActions(for: .touchDown)
        container.closeButton.sendActions(for: .touchUpInside)
        #expect(closes == 1)

        container.dismissButton.sendActions(for: .touchDown)
        container.dismissButton.sendActions(for: .touchUpInside)
        #expect(!controller.toolbar.isVisible)
    }
}

@Suite("Radial controls live view, gesture coordination, Release policy and Escape preservation", .serialized)
@MainActor
struct RadialControlsLiveViewTests {
    /// Regression for Findings R1 & R2 in a real UIWindow + SwiftUI/UIKit view hierarchy:
    /// - Outside points hit `DesktopView` directly (no blocking full-screen backdrop).
    /// - Common-ancestor coordinator owns outside single-tap dismissal and two-finger
    ///   double-tap across both `DesktopView` and all four radial buttons.
    /// - Recognizer failure dependencies block only remote single-tap click while
    ///   keeping drag, pan, pinch, scroll, long-press, hover, and right-click unblocked.
    @Test func hitTestingGestureCoordinationAndRemoteGesturesWhileRadialMenuIsVisible() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let insets = UIEdgeInsets(top: 0, left: 68, bottom: 20, right: 68)
        let window = SafeAreaTestWindow(
            windowScene: scene,
            frame: CGRect(x: 0, y: 0, width: 912, height: 420),
            safeAreaInsets: insets
        )
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeRadialToolbar(timers))
        var closed = 0
        var pointerLockHistory: [Bool] = []
        weak var hostRef: SessionHostingController?
        let host = SessionHostingController(rootView: SessionView(
            source: SessionSource(id: "radial-r1-r2", clipURL: nil),
            controller: controller,
            onClose: { closed += 1 },
            onPointerLockPreference: { pointerLockHistory.append($0); hostRef?.pointerLockRequested = $0 }
        ))
        hostRef = host
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        try #require(await settleWindow(window) {
            findViews(RadialMenuContainerView.self, in: host.view).count == 1
                && controller.toolbar.stage == .established
                && findViews(RadialMenuContainerView.self, in: host.view).first?.gestureCoordinator?.hostView != nil
        })

        let desktop = try #require(findViews(DesktopView.self, in: host.view).first)
        let radialContainer = try #require(findViews(RadialMenuContainerView.self, in: host.view).first)
        let coordinator = try #require(radialContainer.gestureCoordinator)
        let ancestor = try #require(coordinator.hostView)

        // 1. Common-ancestor gesture ownership (Finding R2).
        #expect(desktop.isDescendant(of: ancestor))
        #expect(radialContainer.isDescendant(of: ancestor))
        for control in radialContainer.controls {
            #expect(control.isDescendant(of: ancestor))
            #expect(control.isMultipleTouchEnabled)
            #expect(control.gestureRecognizerShouldBegin(coordinator.radialTwoFingerDoubleTap))
        }
        #expect(ancestor.gestureRecognizers?.contains(coordinator.outsideDismissTap) == true)
        #expect(ancestor.gestureRecognizers?.contains(coordinator.radialTwoFingerDoubleTap) == true)

        // DesktopView keeps its original 3 tap recognizers unchanged.
        let desktopTaps = desktop.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        #expect(desktopTaps.count == 3)

        // 2. Hit-testing while visible (Finding R1): outside points hit DesktopView directly;
        //    only the circular radial medallion owns hits inside its radius.
        let safeMarginPoint = CGPoint(x: 16, y: 16)
        let outsidePoint = CGPoint(x: 120, y: 300)
        #expect(window.hitTest(safeMarginPoint, with: nil) === desktop)
        #expect(window.hitTest(outsidePoint, with: nil) === desktop)

        let containerCornerInWindow = radialContainer.convert(CGPoint(x: 2, y: 2), to: window)
        #expect(window.hitTest(containerCornerInWindow, with: nil) === desktop) // outside circle inside square bounds

        for control in radialContainer.controls {
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
            #expect(window.hitTest(center, with: nil)?.isDescendant(of: control) == true)
        }
        // Points inside the circular medallion between buttons hit radialContainer (never DesktopView).
        let hubCenter = radialContainer.dismissButton.center
        let ringGapBetweenHubAndRetina = CGPoint(
            x: hubCenter.x,
            y: (radialContainer.menuButton.frame.maxY + radialContainer.dismissButton.frame.minY) / 2
        )
        let gapLocal = CGPoint(x: hubCenter.x, y: hubCenter.y + (radialContainer.bounds.height * 0.30))
        #expect(window.hitTest(radialContainer.convert(ringGapBetweenHubAndRetina, to: window), with: nil) === radialContainer)
        let gapInWindow = radialContainer.convert(gapLocal, to: window)
        #expect(window.hitTest(gapInWindow, with: nil) === radialContainer)

        // 3. Touch-reception filtering & recognizer failure dependencies (Findings R1 & R2).
        let desktopTouch = TouchSample(view: desktop, pointInView: desktop.convert(outsidePoint, from: window))
        let desktopMouseTouch = TouchSample(view: desktop, pointInView: desktop.convert(outsidePoint, from: window), type: .indirectPointer)
        let menuTouch = TouchSample(view: radialContainer.menuButton, pointInView: CGPoint(x: 32, y: 32))
        let fitTouch = TouchSample(view: radialContainer.fitButton, pointInView: CGPoint(x: 32, y: 32))
        let closeTouch = TouchSample(view: radialContainer.closeButton, pointInView: CGPoint(x: 32, y: 32))
        let dismissTouch = TouchSample(view: radialContainer.dismissButton, pointInView: CGPoint(x: 24, y: 24))
        let ringGapTouch = TouchSample(view: radialContainer, pointInView: gapLocal)

        // outsideDismissTap receives only touches on DesktopView outside the radial circle.
        #expect(coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))
        #expect(coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopMouseTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: menuTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: fitTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: closeTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: dismissTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: ringGapTouch))
        #expect(coordinator.outsideDismissTap.delaysTouchesBegan && coordinator.outsideDismissTap.cancelsTouchesInView)

        // outsideDismissTap suppresses ONLY DesktopView's single-tap click; pan, pinch,
        // long-press, scroll wheel, hover, and right-click remain unblocked!
        #expect(coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.singleTapRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.panRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.pinchRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.longPressRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.rightTapRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: desktop.toolbarToggleRecognizer))
        for recognizer in desktop.gestureRecognizers ?? [] where recognizer !== desktop.singleTapRecognizer {
            #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldBeRequiredToFailBy: recognizer))
        }

        // radialTwoFingerDoubleTap receives touches on DesktopView AND all radial controls (Finding R2).
        #expect(coordinator.radialTwoFingerDoubleTap.numberOfTouchesRequired == 2)
        #expect(coordinator.radialTwoFingerDoubleTap.numberOfTapsRequired == 2)
        #expect(coordinator.radialTwoFingerDoubleTap.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        #expect(coordinator.radialTwoFingerDoubleTap.delaysTouchesEnded && coordinator.radialTwoFingerDoubleTap.cancelsTouchesInView)
        for touch in [desktopTouch, menuTouch, fitTouch, closeTouch, dismissTouch, ringGapTouch] {
            #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldReceive: touch))
        }
        #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.toolbarToggleRecognizer))
        #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.rightTapRecognizer))
        #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.singleTapRecognizer))
        #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: coordinator.outsideDismissTap))
        #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: radialContainer.ringTapRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.panRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.pinchRecognizer))
        #expect(!coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: desktop.longPressRecognizer))
        // Non-long-press recognizers on SessionMenuControl (e.g. menu presentation) yield to two-finger double tap.
        for recognizer in radialContainer.menuButton.gestureRecognizers ?? [] {
            let isLongHold = (recognizer as? UILongPressGestureRecognizer).map { $0.minimumPressDuration > 0.1 } ?? false
            #expect(coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldBeRequiredToFailBy: recognizer) == !isLongHold)
        }

        // Pressing a radial control or opening the Retina menu suspends outside tap dismissal.
        radialContainer.fitButton.sendActions(for: .touchDown)
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))
        radialContainer.fitButton.sendActions(for: .touchCancel)
        #expect(coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))
        controller.toolbar.setMenuOpen(true)
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))
        controller.toolbar.setMenuOpen(false)
        #expect(coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))

        // 4. Remote drag, local pan, pinch, and two-finger scroll remain available while radial menu is visible!
        var remoteInputs: [ViewInput] = []
        let wiredOnInput = desktop.onInput
        desktop.onInput = { event in remoteInputs.append(event); wiredOnInput?(event) }

        let renderer = try #require(controller.renderer)
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 1600, canvasHeight: 800,
                                  pictureWidth: 1600, pictureHeight: 200, cropTop: 0, visibleHeight: 200)
        renderer.shown = DesktopSnapshot(updateSequence: 1, rtpTimestamp: 1, generation: 1, layout: layout,
                                         stripes: [nil, nil, nil, nil], changedStripes: [], newestSubmitNanos: 0)
        renderer.viewportPixels = CGRect(x: 0, y: 0, width: 912, height: 420)

        // Pinch-to-zoom while radial menu is visible.
        let pinch = PinchSample()
        pinch.send(to: desktop, .began, at: outsidePoint)
        pinch.send(to: desktop, .changed, scale: 1.5, at: outsidePoint)
        pinch.send(to: desktop, .ended, at: outsidePoint)
        #expect(renderer.zoom > 1.4 && controller.toolbar.isVisible)

        // Local pan while radial menu is visible.
        controller.panEnabled = true
        desktop.panEnabled = true
        let pan = PanGestureSample()
        pan.sampleState = .changed; pan.fingers = 1; pan.delta = CGPoint(x: 30, y: 20)
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        #expect(renderer.pan != .zero && controller.toolbar.isVisible)
        controller.panEnabled = false
        desktop.panEnabled = false

        // Trackpad pointer move while radial menu is visible.
        remoteInputs.removeAll()
        pan.sampleState = .changed; pan.fingers = 1; pan.delta = CGPoint(x: 15, y: 10)
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        #expect(remoteInputs.contains { if case .relative = $0 { true } else { false } })
        #expect(controller.toolbar.isVisible) // pointer motion alone never dismisses

        // Direct-mode 1-finger drag while radial menu is visible emits button-down and absolute drag.
        controller.trackpad = false
        desktop.trackpad = false
        remoteInputs.removeAll()
        pan.sampleState = .began; pan.fingers = 1; pan.point = outsidePoint
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        pan.sampleState = .changed; pan.point = CGPoint(x: outsidePoint.x + 20, y: outsidePoint.y + 12)
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        pan.sampleState = .ended
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        #expect(remoteInputs.contains { if case .button(_, 1, false) = $0 { true } else { false } })
        #expect(remoteInputs.contains { if case .absolute = $0 { true } else { false } })
        #expect(remoteInputs.contains { if case .release = $0 { true } else { false } })
        controller.trackpad = true
        desktop.trackpad = true

        // Two-finger scroll while radial menu is visible delivers wheel events.
        remoteInputs.removeAll()
        pan.sampleState = .changed; pan.fingers = 2; pan.delta = CGPoint(x: 0, y: 24)
        _ = desktop.perform(NSSelectorFromString("moved:"), with: pan)
        #expect(remoteInputs.contains { if case .wheel = $0 { true } else { false } })

        // Ring gap tap inside the medallion refreshes timeout locally without remote input.
        remoteInputs.removeAll()
        let beforeRingTap = try #require(timers.live.first)
        fireTapRecognizer(radialContainer.ringTapRecognizer, on: radialContainer, selector: "handleRingGapTap:", at: gapLocal)
        #expect(controller.toolbar.isVisible && beforeRingTap.cancelled && timers.live.count == 1 && remoteInputs.isEmpty)

        // 5. Outside single-tap dismisses locally with zero remote click and restores pointer lock!
        remoteInputs.removeAll()
        #expect(!host.prefersPointerLocked)
        fireTapRecognizer(coordinator.outsideDismissTap, on: coordinator, selector: "handleOutsideDismissTap:", at: outsidePoint)
        // Immediately (mid-exit animation): container stops intercepting and coordinator stops receiving!
        #expect(!controller.toolbar.isVisible)
        #expect(!radialContainer.point(inside: radialContainer.dismissButton.center, with: nil))
        #expect(!coordinator.gestureRecognizer(coordinator.outsideDismissTap, shouldReceive: desktopTouch))
        #expect(!coordinator.gestureRecognizer(coordinator.radialTwoFingerDoubleTap, shouldReceive: menuTouch))
        #expect(remoteInputs.isEmpty)

        try #require(await settleWindow(window) {
            findViews(RadialMenuContainerView.self, in: host.view).isEmpty
                && host.prefersPointerLocked
        })
        // Coordinator recognizers are cleanly detached from the ancestor when hidden.
        #expect(ancestor.gestureRecognizers?.contains(coordinator.outsideDismissTap) != true)
        #expect(ancestor.gestureRecognizers?.contains(coordinator.radialTwoFingerDoubleTap) != true)
        #expect(pointerLockHistory == [false, true])

        // 6. Re-open via two-finger double tap near edge, then close via two-finger double tap over radial menu:
        //    no command activates, no remote input leaks, and pointer lock hands over cleanly!
        let edgeTap = TapSample()
        edgeTap.point = CGPoint(x: 10, y: 10)
        edgeTap.send(to: desktop, "toolbarToggled:")
        try #require(await settleWindow(window) {
            guard controller.toolbar.isVisible,
                  let container = findViews(RadialMenuContainerView.self, in: host.view).first,
                  container.gestureCoordinator?.hostView != nil else { return false }
            let center = container.dismissButton.convert(CGPoint(x: container.dismissButton.bounds.midX, y: container.dismissButton.bounds.midY), to: window)
            return window.hitTest(center, with: nil)?.isDescendant(of: container.dismissButton) == true
        })
        #expect(!host.prefersPointerLocked)

        let reopened = try #require(findViews(RadialMenuContainerView.self, in: host.view).first)
        let reopenedCoordinator = try #require(reopened.gestureCoordinator)
        // Simulate button touchDown started on Close just before two-finger double tap resolves.
        reopened.closeButton.sendActions(for: .touchDown)
        #expect(controller.toolbar.isControlPressed)
        fireTapRecognizer(reopenedCoordinator.radialTwoFingerDoubleTap, on: reopenedCoordinator, selector: "handleTwoFingerDoubleTap:")
        #expect(!controller.toolbar.isVisible && !controller.toolbar.isControlPressed && closed == 0 && remoteInputs.isEmpty)
        try #require(await settleWindow(window) {
            findViews(RadialMenuContainerView.self, in: host.view).isEmpty && host.prefersPointerLocked
        })
        #expect(pointerLockHistory == [false, true, false, true])

        // 7. Auto-dismissal (5-second inactivity timeout) detaches recognizers and restores pointer lock,
        //    while a held remote button defers pointer lock until release.
        desktop.onToolbarToggle?()
        try #require(await settleWindow(window) {
            findViews(RadialMenuContainerView.self, in: host.view).count == 1 && !host.prefersPointerLocked
        })
        controller.toolbar.setRemoteButtonHeld(true)
        timers.fire(try #require(timers.live.first))
        try #require(await settleWindow(window) {
            findViews(RadialMenuContainerView.self, in: host.view).isEmpty
        })
        #expect(!host.prefersPointerLocked) // remote button still held
        controller.toolbar.setRemoteButtonHeld(false)
        try #require(await settleWindow(window) { host.prefersPointerLocked })
        #expect(ancestor.gestureRecognizers?.contains(reopenedCoordinator.outsideDismissTap) != true)
    }

    @Test func radialMenuCommandsPlacementHitTestingAndAccessibilityInLiveWindow() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let insets = UIEdgeInsets(top: 0, left: 68, bottom: 20, right: 68)
        let window = SafeAreaTestWindow(
            windowScene: scene,
            frame: CGRect(x: 0, y: 0, width: 912, height: 420),
            safeAreaInsets: insets
        )
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeRadialToolbar(timers))
        var closed = 0
        let host = SessionHostingController(rootView: SessionView(
            source: SessionSource(id: "radial-live", clipURL: nil),
            controller: controller,
            onClose: { closed += 1 }
        ))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        try #require(await settleWindow(window) {
            findViews(SessionMenuControl.self, in: host.view).count == 1
                && findViews(SessionDismissButton.self, in: host.view).count == 1
                && controller.toolbar.stage == .established
        })

        let desktop = try #require(findViews(DesktopView.self, in: host.view).first)
        var remoteInputs: [ViewInput] = []
        let wiredOnInput = desktop.onInput
        desktop.onInput = { event in remoteInputs.append(event); wiredOnInput?(event) }

        let menuButton = try #require(findViews(SessionMenuControl.self, in: host.view).first)
        let actionButtons = findViews(SessionActionButton.self, in: host.view)
        let dismissButton = try #require(findViews(SessionDismissButton.self, in: host.view).first)
        let radialContainer = try #require(findViews(RadialMenuContainerView.self, in: host.view).first)

        // Exactly three radial commands (Retina, Fit, Close) plus central dismiss hub; never Esc or HUD.
        #expect(menuButton.configuration?.title == "Retina")
        #expect(Set(actionButtons.compactMap { $0.configuration?.title }) == ["Fit", "Close"])
        #expect(actionButtons.count == 2)
        #expect(!actionButtons.contains { $0.configuration?.title == "Esc" })
        #expect(!actionButtons.contains { $0.configuration?.title?.contains("HUD") == true })

        // Accessibility labels, hints, traversal order, Escape action, and minimum 44x44 targets.
        let fitButton = try #require(actionButtons.first { $0.configuration?.title == "Fit" })
        let closeButton = try #require(actionButtons.first { $0.configuration?.title == "Close" })
        #expect(menuButton.accessibilityLabel == "Retina")
        #expect(menuButton.accessibilityHint == "Opens display, input and keyboard options.")
        #expect(fitButton.accessibilityLabel == "Fit")
        #expect(fitButton.accessibilityHint == "Shows the whole remote desktop.")
        #expect(closeButton.accessibilityLabel == "Close")
        #expect(closeButton.accessibilityHint == "Ends the session.")
        #expect(dismissButton.accessibilityLabel == "Dismiss session controls")
        #expect(dismissButton.isEnabled)
        #expect((radialContainer.accessibilityElements as? [NSObject]) == [menuButton, fitButton, closeButton, dismissButton])
        for control in [menuButton as UIView, fitButton, closeButton, dismissButton] {
            #expect(control.bounds.width >= 44 && control.bounds.height >= 44)
        }

        // Retina menu preserves all existing actions.
        let menuTitles = menuButton.menu?.children.map(\.title)
        #expect(menuTitles == ["Retina", "More Space", "Local pan (one finger)", "Input", "Keyboard"])
        controller.setProfile(.moreSpace)
        try #require(await settleWindow(window) { menuButton.configuration?.title == "More Space" })
        #expect(menuButton.accessibilityLabel == "More Space")

        // Fit executes controller.fit() and keeps the menu open with a fresh 5s timeout.
        let renderer = try #require(controller.renderer)
        renderer.zoom = 2.5
        fitButton.sendActions(for: .touchDown)
        fitButton.sendActions(for: .touchUpInside)
        #expect(renderer.zoom == 1 && controller.toolbar.isVisible && timers.live.count == 1)

        // Close executes onClose.
        closeButton.sendActions(for: .touchDown)
        closeButton.sendActions(for: .touchUpInside)
        #expect(closed == 1)

        // VoiceOver Escape gesture on radial container dismisses cleanly.
        #expect(radialContainer.accessibilityPerformEscape())
        try #require(await settleWindow(window) {
            !controller.toolbar.isVisible && findViews(SessionMenuControl.self, in: host.view).isEmpty
        })
        #expect(remoteInputs.isEmpty)

        // Re-open near top-left edge via two-finger double tap: clamps inside safe areas.
        let edgeTap = TapSample()
        edgeTap.point = CGPoint(x: 10, y: 10)
        edgeTap.send(to: desktop, "toolbarToggled:")
        try #require(await settleWindow(window) {
            guard controller.toolbar.isVisible,
                  let dismiss = findViews(SessionDismissButton.self, in: host.view).first else { return false }
            let center = dismiss.convert(CGPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), to: window)
            return window.hitTest(center, with: nil)?.isDescendant(of: dismiss) == true
        })
        let reopenedDismiss = try #require(findViews(SessionDismissButton.self, in: host.view).first)
        let reopenedMenu = try #require(findViews(SessionMenuControl.self, in: host.view).first)
        let reopenedFit = try #require(findViews(SessionActionButton.self, in: host.view).first { $0.configuration?.title == "Fit" })
        let reopenedClose = try #require(findViews(SessionActionButton.self, in: host.view).first { $0.configuration?.title == "Close" })
        let safeRect = window.bounds.inset(by: insets)
        for control in [reopenedDismiss as UIView, reopenedMenu, reopenedFit, reopenedClose] {
            let rect = control.convert(control.bounds, to: window)
            #expect(safeRect.contains(rect))
        }

        // Central hub dismissal hides the menu locally with zero remote input.
        let dismissCenter = reopenedDismiss.convert(CGPoint(x: reopenedDismiss.bounds.midX, y: reopenedDismiss.bounds.midY), to: window)
        #expect(window.hitTest(dismissCenter, with: nil)?.isDescendant(of: reopenedDismiss) == true)
        reopenedDismiss.sendActions(for: .touchDown)
        reopenedDismiss.sendActions(for: .touchUpInside)
        try #require(await settleWindow(window) {
            !controller.toolbar.isVisible && findViews(SessionDismissButton.self, in: host.view).isEmpty
        })
        #expect(remoteInputs.isEmpty)
        #expect(window.hitTest(dismissCenter, with: nil) === desktop)

        // Remote desktop gestures work normally once dismissed.
        let clickTap = TapSample()
        clickTap.point = CGPoint(x: 400, y: 200)
        clickTap.send(to: desktop, "tapped:")
        clickTap.send(to: desktop, "rightTapped:")
        let clickMasks = remoteInputs.compactMap { input -> UInt8? in
            if case .click(_, let mask, _) = input { return mask }
            return nil
        }
        #expect(clickMasks == [1, 4])
    }

    @Test(arguments: [
        (CGSize(width: 420, height: 912), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        (CGSize(width: 912, height: 420), UIEdgeInsets(top: 0, left: 68, bottom: 20, right: 68)),
        (CGSize(width: 834, height: 1194), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        (CGSize(width: 1194, height: 834), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
    ])
    func adaptsAcrossOrientationsAndDeviceSizesWithoutClipping(_ size: CGSize, _ insets: UIEdgeInsets) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = SafeAreaTestWindow(windowScene: scene, frame: CGRect(origin: .zero, size: size), safeAreaInsets: insets)
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeRadialToolbar(timers))
        let host = SessionHostingController(rootView: SessionView(
            source: SessionSource(id: "radial-orient", clipURL: nil),
            controller: controller,
            onClose: {}
        ))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        try #require(await settleWindow(window) {
            findViews(SessionMenuControl.self, in: host.view).count == 1
                && controller.toolbar.stage == .established
        })

        // Re-open anchored at the bottom-right corner and verify safe-area containment.
        controller.toolbar.dismiss()
        try #require(await settleWindow(window) {
            findViews(SessionDismissButton.self, in: host.view).isEmpty
        })
        controller.toolbar.toggle(at: CGPoint(x: size.width, y: size.height))
        let safeRect = window.bounds.inset(by: insets)
        try #require(await settleWindow(window) {
            let current: [UIView] = findViews(SessionToolbarControl.self, in: host.view)
            guard current.count == 4, let dismiss = findViews(SessionDismissButton.self, in: host.view).first else { return false }
            let dismissRect = dismiss.convert(dismiss.bounds, to: window)
            return dismissRect.width >= 44 && dismissRect.height >= 44 && dismissRect.midY > safeRect.midY
        })
        let controls: [UIView] = findViews(SessionToolbarControl.self, in: host.view)
        #expect(controls.count == 4) // Retina, Fit, Close, Center Dismiss
        for control in controls {
            let rect = control.convert(control.bounds, to: window)
            #expect(rect.width >= 44 && rect.height >= 44)
            #expect(safeRect.contains(rect))
        }

        // Rotate / swap dimensions live and verify controls remain cleanly inside the new safe area.
        let rotated = CGSize(width: size.height, height: size.width)
        let rotatedInsets = UIEdgeInsets(top: insets.left, left: insets.top, bottom: insets.right, right: insets.bottom)
        window.customSafeAreaInsets = rotatedInsets
        window.frame = CGRect(origin: .zero, size: rotated)
        host.view.setNeedsLayout()
        let rotatedSafeRect = window.bounds.inset(by: rotatedInsets)
        try #require(await settleWindow(window) {
            let current: [UIView] = findViews(SessionToolbarControl.self, in: host.view)
            return current.count == 4 && current.allSatisfy { rotatedSafeRect.contains($0.convert($0.bounds, to: window)) }
        })
    }

    @Test func dynamicTypeAccessibilitySizePreservesNonOverlappingRadialLayout() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let insets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        let window = SafeAreaTestWindow(
            windowScene: scene,
            frame: CGRect(x: 0, y: 0, width: 420, height: 912),
            safeAreaInsets: insets
        )
        let timers = ManualSchedule(), controller = SessionController(toolbar: makeRadialToolbar(timers))
        controller.setProfile(.moreSpace)
        let host = UIHostingController(rootView: SessionView(
            source: SessionSource(id: "radial-ax5", clipURL: nil),
            controller: controller,
            onClose: {}
        ).environment(\.dynamicTypeSize, .accessibility5))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        try #require(await settleWindow(window) {
            findViews(SessionToolbarControl.self, in: host.view).count == 4
                && controller.toolbar.stage == .established
        })

        let safeRect = window.bounds.inset(by: insets)
        let controls = findViews(SessionToolbarControl.self, in: host.view)
        let frames = controls.map { $0.convert($0.bounds, to: window) }
        for frame in frames {
            #expect(frame.width >= 44 && frame.height >= 44)
            #expect(safeRect.contains(frame))
        }
        // Circular controls must not overlap each other even at AX5 Dynamic Type.
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let a = frames[i], b = frames[j]
                let distance = hypot(a.midX - b.midX, a.midY - b.midY)
                #expect(distance >= (a.width + b.width) / 2 + 2)
            }
        }
        // Overall radial bounding box stays compact within target range (~180-220 pt).
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        #expect(union.width <= 220 && union.height <= 220)
    }

    @Test func hudAndEscAreAbsentFromProductionSessionView() {
        let view = SessionView(source: SessionSource(id: "release-check", clipURL: nil), onClose: {})
        let labels = Set(Mirror(reflecting: view).children.compactMap(\.label))
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        #expect(labels.contains(where: { $0.hasSuffix("showHUD") }))
        #else
        #expect(!labels.contains(where: { $0.hasSuffix("showHUD") }))
        #endif
    }

    @Test func hardwareEscapeAndKeyboardAccessoryEscapeRemainIntact() throws {
        let view = DesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var keys: [(UInt32, Bool)] = []
        view.onInput = { input in
            if case .key(let symbol, let down) = input { keys.append((symbol, down)) }
        }

        // Physical hardware Escape key path.
        view.keyDown(.keyboardEscape, symbol: 0xff1b)
        view.keyUp(.keyboardEscape)
        #expect(keys.count == 2 && keys[0] == (0xff1b, true) && keys[1] == (0xff1b, false))

        // On-screen keyboard accessory bar Escape path.
        keys.removeAll()
        view.keyboardShown = true
        let scroll = try #require(view.inputAccessoryView as? UIScrollView)
        let bar = try #require(scroll.subviews.first as? UIToolbar)
        let escItem = try #require(bar.items?.first { $0.title == "Esc" })
        _ = view.perform(NSSelectorFromString("accessory:"), with: escItem)
        #expect(keys.count == 2 && keys[0] == (0xff1b, true) && keys[1] == (0xff1b, false))
    }
}
