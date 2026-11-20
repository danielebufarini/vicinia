// Vicinia — UIView hosting the CAMetalLayer; reports the real viewport geometry.
// SPDX-License-Identifier: MIT

import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass
import GameController

#if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
/// Never recognizes and never interferes: it only records the UIKit timestamp
/// of the newest touch sample, the origin of local cursor latency.
private final class TouchClock: UIGestureRecognizer {
    private(set) var latest: TimeInterval = 0
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { latest = event.timestamp }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { latest = event.timestamp }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { latest = event.timestamp; state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}
#endif

/// Geometry measured from the live window scene and view (never nominal tables).
struct ViewportGeometry: Equatable {
    var boundsPoints: CGSize
    var displayScale: CGFloat
    var safeArea: UIEdgeInsets
    var drawablePixels: CGSize
    var interfaceOrientation: String
    var maximumFramesPerSecond: Int

    /// The useful viewport (inside safe areas), in drawable pixels.
    var usefulPixels: CGRect {
        CGRect(x: (safeArea.left * displayScale).rounded(.up), y: (safeArea.top * displayScale).rounded(.up),
               width: ((boundsPoints.width - safeArea.left - safeArea.right) * displayScale).rounded(.down),
               height: ((boundsPoints.height - safeArea.top - safeArea.bottom) * displayScale).rounded(.down))
            .intersection(CGRect(origin: .zero, size: drawablePixels))
    }
    /// Retina = remote 2×: backing = useful pixels rounded down to even values.
    var retinaBacking: (width: Int, height: Int) {
        (Int(usefulPixels.width) / 2 * 2, Int(usefulPixels.height) / 2 * 2)
    }

    var summary: String {
        let b = retinaBacking
        return "orientation=\(interfaceOrientation) bounds=\(Int(boundsPoints.width))x\(Int(boundsPoints.height))pt "
            + "scale=\(displayScale) safeArea(t,l,b,r)=(\(safeArea.top),\(safeArea.left),\(safeArea.bottom),\(safeArea.right))pt "
            + "drawable=\(Int(drawablePixels.width))x\(Int(drawablePixels.height))px "
            + "useful=\(Int(usefulPixels.width))x\(Int(usefulPixels.height))px "
            + "retinaBacking=\(b.width)x\(b.height) (logical \(b.width / 2)x\(b.height / 2)) "
            + "moreSpace=\(b.width)x\(b.height)@1x maxFPS=\(maximumFramesPerSecond)"
    }
}

final class DesktopView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onGeometry: ((ViewportGeometry) -> Void)?
    var onZoom: ((CGFloat, CGPoint, CGPoint) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var onKeyboardShown: ((Bool) -> Void)?
    var onInput: ((ViewInput) -> Void)?
    /// Local only: shows or hides the session toolbar; never remote input.
    var onToolbarToggle: (() -> Void)?
    /// Local only: reports the two-finger double-tap activation point (window
    /// coordinates when attached to a window, otherwise view coordinates).
    var onToolbarToggleAt: ((CGPoint) -> Void)?
    /// Mirrors the toolbar for the accessibility action and VoiceOver focus.
    var toolbarVisible = true {
        didSet {
            // Hidden controls leave the hierarchy: keep VoiceOver on the desktop.
            if oldValue, !toolbarVisible, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .layoutChanged, argument: self)
            }
        }
    }
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Timestamp (system uptime) of the UIKit event behind the input being
    /// delivered; valid while `onInput` runs.
    private(set) var inputEventTime: TimeInterval = 0
    private let clock = TouchClock()
    #endif
    private var touchTime: TimeInterval {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        clock.latest > 0 ? clock.latest : ProcessInfo.processInfo.systemUptime
        #else
        0
        #endif
    }
    private func emit(_ input: ViewInput, at time: @autoclosure () -> TimeInterval? = nil) {
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        inputEventTime = time() ?? ProcessInfo.processInfo.systemUptime
        #endif
        onInput?(input)
    }
    var trackpad = true { didSet { if oldValue != trackpad { cancelInput() } } }
    var panEnabled = false { didSet { if oldValue != panEnabled { cancelInput() } } }
    var keyboardShown = false {
        didSet { if oldValue != keyboardShown { reloadInputViews(); becomeFirstResponder() } }
    }
    private var dragging = false
    private var holdDragging = false
    private var scrollRemainder = CGPoint.zero
    private var pinchCentroid: CGPoint?
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var motion = UIPanGestureRecognizer(target: self, action: #selector(moved))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
    private lazy var right = UITapGestureRecognizer(target: self, action: #selector(rightTapped))
    private lazy var toolbarToggle = UITapGestureRecognizer(target: self, action: #selector(toolbarToggled))
    var singleTapRecognizer: UITapGestureRecognizer { tap }
    var rightTapRecognizer: UITapGestureRecognizer { right }
    var toolbarToggleRecognizer: UITapGestureRecognizer { toolbarToggle }
    var panRecognizer: UIPanGestureRecognizer { motion }
    var pinchRecognizer: UIPinchGestureRecognizer { pinch }
    var longPressRecognizer: UILongPressGestureRecognizer { hold }
    private var mice: [GCMouse] = []
    @objc private func bindMice() {
        for m in mice { m.mouseInput?.mouseMovedHandler = nil; m.mouseInput?.leftButton.pressedChangedHandler = nil; m.mouseInput?.rightButton?.pressedChangedHandler = nil; m.mouseInput?.middleButton?.pressedChangedHandler = nil }
        mice = window == nil ? [] : GCMouse.mice()
        for mouse in mice {
            mouse.handlerQueue = .main
            mouse.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
                MainActor.assumeIsolated {
                    guard let self, !self.panEnabled, self.window?.windowScene?.pointerLockState?.isLocked == true else { return }
                    self.emit(.relative(CGPoint(x: CGFloat(dx), y: -CGFloat(dy))))
                }
            }
            let input = mouse.mouseInput
            for (button, mask) in [(input?.leftButton, UInt8(1)), (input?.rightButton, UInt8(4)), (input?.middleButton, UInt8(2))] {
                button?.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated {
                        guard let self, !self.panEnabled, self.window?.windowScene?.pointerLockState?.isLocked == true else { return }
                        if pressed { self.mouseButtons |= mask } else { self.mouseButtons &= ~mask }
                        self.emit(.button(.zero, self.mouseButtons, true))
                    }
                }
            }
        }
    }
    private var mouseButtons: UInt8 = 0
    private var reported: ViewportGeometry?
    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { keyboardShown ? nil : UIView(frame: .zero) }
    override var inputAccessoryView: UIView? {
        guard keyboardShown else { return nil }
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        bar.items = ["Esc", "@", "#", "[", "]", "{", "}", "\\", "|", "~", "`", "Hide"].map {
            UIBarButtonItem(title: $0, style: .plain, target: self, action: #selector(accessory(_:)))
        }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 44))
        scroll.autoresizingMask = [.flexibleWidth]
        bar.frame.size.width = 660
        scroll.contentSize = bar.frame.size
        scroll.addSubview(bar)
        return scroll
    }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var hasText: Bool { true }
    func insertText(_ text: String) {
        for c in text.unicodeScalars where c.value < 128 {
            let key: UInt32 = c.value == 10 ? 0xff0d : c.value
            emit(.key(key, true)); emit(.key(key, false))
        }
    }
    func deleteBackward() { stroke(0xff08) }
    func stroke(_ key: UInt32) { emit(.key(key, true)); emit(.key(key, false)) }
    @objc private func accessory(_ item: UIBarButtonItem) {
        if item.title == "Hide" { keyboardShown = false; onKeyboardShown?(false) }
        else if item.title == "Esc" { stroke(0xff1b) }
        else { insertText(item.title ?? "") }
    }
    func cancelInput() { dragging = false; holdDragging = false; mouseButtons = 0; physicalKeys.removeAll(); scrollRemainder = .zero; pinchCentroid = nil; emit(.release) }
    /// Pointer-lock handover (toolbar-driven hide/show): the pointer changes owner, so local
    /// drag/button state is dropped and remotely held buttons are released. Physically held keys
    /// survive: the user never released them and their key-up is still to come. Unconditional and
    /// idempotent: the notification fires for both lock directions and is delivered asynchronously,
    /// so by handler time the system state may already have flipped again (rapid toggles) — a
    /// pointer-only barrier is correct in every interleaving, while a full release would drop held
    /// keys. Genuine focus loss, lifecycle changes, geometry invalidation and termination keep the
    /// full barrier in `cancelInput()`.
    func cancelPointer() { dragging = false; holdDragging = false; mouseButtons = 0; scrollRemainder = .zero; pinchCentroid = nil; emit(.pointerRelease) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isMultipleTouchEnabled = true
        right.numberOfTouchesRequired = 2
        tap.require(toFail: right)
        toolbarToggle.numberOfTouchesRequired = 2
        toolbarToggle.numberOfTapsRequired = 2
        hold.minimumPressDuration = 0.35
        for g in [pinch, tap, right, toolbarToggle, motion, hold] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            g.delegate = self
            addGestureRecognizer(g)
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        clock.cancelsTouchesInView = false
        clock.delaysTouchesEnded = false
        addGestureRecognizer(clock)
        #endif
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        addGestureRecognizer(hover)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(wheel)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Remote Mac desktop")
        accessibilityHint = String(localized: "Shows or hides the session toolbar.")
        NotificationCenter.default.addObserver(self, selector: #selector(pointerLockChanged), name: UIPointerLockState.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(bindMice), name: .GCMouseDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mouseDisconnected), name: .GCMouseDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusLost), name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func mouseDisconnected() { cancelInput(); bindMice() }
    @objc private func focusLost() { cancelInput() }
    @objc private func pointerLockChanged() { cancelPointer() }
    override func resignFirstResponder() -> Bool { cancelInput(); return super.resignFirstResponder() }

    @objc private func pinchChanged(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            cancelInput()
            pinchCentroid = g.location(in: self)
            g.scale = 1
        case .changed:
            let point = g.location(in: self)
            onZoom?(g.scale, pinchCentroid ?? point, point)
            pinchCentroid = point
            g.scale = 1
        case .ended, .cancelled, .failed:
            pinchCentroid = nil
            g.scale = 1
        default: break
        }
    }
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard !panEnabled, g.state == .ended else { return }
        emit(.click(g.location(in: self), 1, trackpad), at: touchTime)
    }
    @objc private func rightTapped(_ g: UITapGestureRecognizer) {
        guard !panEnabled, g.state == .ended else { return }
        emit(.click(g.location(in: self), 4, trackpad), at: touchTime)
    }
    /// Two-finger double tap: local in every input mode, including local pan.
    @objc private func toolbarToggled(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let point = g.location(in: window ?? self)
        if let onToolbarToggleAt {
            onToolbarToggleAt(point)
        } else {
            onToolbarToggle?()
        }
    }
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard !panEnabled else { return }
        switch g.state {
        case .began: dragging = true; holdDragging = true; emit(.button(g.location(in: self), 1, trackpad), at: touchTime)
        case .changed:
            if !trackpad { emit(.absolute(g.location(in: self)), at: touchTime) }
        case .ended, .cancelled, .failed:
            // A long press that never began owns no button. Its failure must
            // not release a concurrent Direct pan which just acquired it.
            if holdDragging { cancelInput() }
        default: break
        }
    }
    @objc private func moved(_ g: UIPanGestureRecognizer) {
        let delta = g.translation(in: self); g.setTranslation(.zero, in: self)
        if panEnabled { if g.state == .changed { onPan?(delta) }; return }
        if g.numberOfTouches == 2 {
            if dragging { cancelInput() }
            if g.state == .changed { scroll(delta) }
        } else {
            if !trackpad, !dragging, g.state == .began { dragging = true; emit(.button(g.location(in: self), 1, false), at: touchTime) }
            if g.state == .changed {
                emit(trackpad ? .relative(delta) : .absolute(g.location(in: self)), at: touchTime)
            }
        }
        if [.ended, .cancelled, .failed].contains(g.state) { cancelInput() }
    }
    private func scroll(_ delta: CGPoint) {
        scrollRemainder.x += delta.x; scrollRemainder.y += delta.y
        for axis in 0..<2 {
            var value = axis == 0 ? scrollRemainder.x : scrollRemainder.y
            let steps = min(64, Int(abs(value)))
            if steps > 0 {
                let button: UInt8 = axis == 0 ? (value > 0 ? 32 : 64) : (value > 0 ? 8 : 16)
                emit(.wheel(button, steps))
                value -= CGFloat(steps) * (value > 0 ? 1 : -1)
            }
            if axis == 0 { scrollRemainder.x = value } else { scrollRemainder.y = value }
        }
    }
    @objc private func wheeled(_ g: UIPanGestureRecognizer) {
        guard !panEnabled else { return }
        scroll(g.translation(in: self)); g.setTranslation(.zero, in: self)
    }
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard !panEnabled else { return }
        guard window?.windowScene?.pointerLockState?.isLocked != true else { return }
        emit(.absolute(g.location(in: self)))
    }
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        (a === motion && b === hold) || (a === hold && b === motion)
    }
    /// A two-finger tap becomes a right-click only after it can no longer be
    /// the first tap of the local toolbar double tap, so neither tap of that
    /// gesture reaches the Mac. The one-finger tap already waits for `right`.
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRequireFailureOf b: UIGestureRecognizer) -> Bool {
        a === right && b === toolbarToggle
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    private func hardwareTouches(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard !panEnabled, let t = touches.first else { return }
        if t.type == .pencil {
            emit(.absolute(t.location(in: self)), at: t.timestamp)
            if t.phase == .began { emit(.button(t.location(in: self), 1, false), at: t.timestamp) }
            if ended { emit(.release) }
        } else if t.type == .indirectPointer {
            guard window?.windowScene?.pointerLockState?.isLocked != true else { return }
            let m = event?.buttonMask ?? []
            let mask: UInt8 = (m.contains(.primary) ? 1 : 0) | (m.contains(.secondary) ? 4 : 0) | (m.contains(.button(3)) ? 2 : 0)
            emit(.button(t.location(in: self), ended ? 0 : mask, false), at: t.timestamp)
        }
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { hardwareTouches(t, event: e, ended: false) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { hardwareTouches(t, event: e, ended: false) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { hardwareTouches(t, event: e, ended: true) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        // Recognizers own finger cancellation. UIKit cancels their raw touches
        // on takeover; that is not cancellation of the recognized drag.
        if t.contains(where: { $0.type != .direct }) { cancelInput() }
    }

    private var physicalKeys: [UIKeyboardHIDUsage: UInt32] = [:]
    private func keySymbol(_ key: UIKey) -> UInt32? {
        let special: [UIKeyboardHIDUsage: UInt32] = [.keyboardReturnOrEnter: 0xff0d, .keyboardEscape: 0xff1b,
            .keyboardDeleteOrBackspace: 0xff08, .keyboardTab: 0xff09, .keyboardLeftArrow: 0xff51,
            .keyboardUpArrow: 0xff52, .keyboardRightArrow: 0xff53, .keyboardDownArrow: 0xff54,
            .keyboardLeftControl: 0xffe3, .keyboardRightControl: 0xffe4, .keyboardLeftShift: 0xffe1,
            .keyboardRightShift: 0xffe2, .keyboardLeftAlt: 0xffe9, .keyboardRightAlt: 0xffea,
            .keyboardLeftGUI: 0xffeb, .keyboardRightGUI: 0xffec]
        if let s = special[key.keyCode] { return s }
        let shortcut = !key.modifierFlags.intersection([.command, .control]).isEmpty
        return (shortcut ? key.charactersIgnoringModifiers : key.characters).unicodeScalars.first.flatMap { $0.value < 128 ? $0.value : nil }
    }
    /// Every physical key reaches the Mac unchanged (no local shortcut);
    /// `pressesBegan`/`pressesEnded` delegate here so tests drive this path.
    func keyDown(_ code: UIKeyboardHIDUsage, symbol: UInt32?) {
        if let symbol { physicalKeys[code] = symbol; emit(.key(symbol, true)) }
    }
    func keyUp(_ code: UIKeyboardHIDUsage) {
        if let s = physicalKeys.removeValue(forKey: code) { emit(.key(s, false)) }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses { if let k = p.key { keyDown(k.keyCode, symbol: keySymbol(k)) } }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses { if let k = p.key { keyUp(k.keyCode) } }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { physicalKeys.removeAll(); cancelInput() }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let name = toolbarVisible ? String(localized: "Hide session toolbar") : String(localized: "Show session toolbar")
            return [UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.toggleToolbarForAccessibility() ?? false }]
        }
        set {}
    }
    /// VoiceOver's two-finger double tap (Magic Tap) is the same local toggle.
    override func accessibilityPerformMagicTap() -> Bool { toggleToolbarForAccessibility() }
    /// Activation is local: returning true stops VoiceOver from synthesizing a
    /// tap, which would otherwise become a click on the Mac.
    override func accessibilityActivate() -> Bool { _ = toggleToolbarForAccessibility(); return true }
    private func toggleToolbarForAccessibility() -> Bool {
        guard let onToolbarToggle else { return false }
        onToolbarToggle()
        return true
    }

    override func didMoveToWindow() { super.didMoveToWindow(); report(); if window != nil { becomeFirstResponder() } else { cancelInput() }; bindMice() }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        report()
    }

    private func report() {
        guard let window else { return }
        let scale = traitCollection.displayScale
        contentScaleFactor = scale
        let drawable = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if metalLayer.drawableSize != drawable { metalLayer.drawableSize = drawable }
        let orientation: String = switch window.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        default: "unknown"
        }
        // SwiftUI can transiently expand this view during keyboard dismissal.
        // The session occupies the physical window; keyboard chrome must not
        // redefine the remote display or remove the home-indicator inset.
        let g = ViewportGeometry(boundsPoints: window.bounds.size, displayScale: scale, safeArea: window.safeAreaInsets,
                                 drawablePixels: drawable, interfaceOrientation: orientation,
                                 maximumFramesPerSecond: window.screen.maximumFramesPerSecond)
        guard !g.usefulPixels.isEmpty else { return }    // intermediate scene layout has no usable viewport yet
        guard g != reported else { return }
        reported = g
        onGeometry?(g)
    }
}

// UIKit locations/deltas are converted once by the controller's ViewportTransform.
enum ViewInput {
    case absolute(CGPoint), relative(CGPoint), button(CGPoint, UInt8, Bool), click(CGPoint, UInt8, Bool)
    case wheel(UInt8, Int), key(UInt32, Bool), release, pointerRelease

    /// Click, press, scroll or a non-modifier key-down: deliberate work on the
    /// Mac, which dismisses the toolbar. Pointer motion (including hover on the
    /// way to the toolbar), releases, key-ups and modifiers do not.
    var isIntentionalRemoteAction: Bool {
        switch self {
        case .click, .wheel: true
        case .button(_, let mask, _): mask != 0
        case .key(let keysym, let down): down && !(0xffe1...0xffee).contains(keysym) // X11 modifier keysyms
        case .absolute, .relative, .release, .pointerRelease: false
        }
    }
}
