// Vicinia — compact Liquid Glass radial session controls, layout and
// gesture coordination with `DesktopView`.
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// Pure radial geometry and safe-area clamping for the floating session controls.
/// Adapts between a four-command cardinal layout (`Options`, `Audio`, `Keyboard`, `Close`)
/// for audio-capable live sessions and a three-command layout (`Options`, `Keyboard`, `Close`)
/// for sessions without live audio capability.
struct RadialMenuLayout: Equatable, Sendable {
    enum Command: CaseIterable, Equatable, Sendable {
        case options
        case audio
        case keyboard
        case close
    }

    static let preferredDiameter: CGFloat = 204
    static let preferredFourCommandDiameter: CGFloat = 210
    static let accessibilityDiameter: CGFloat = 216
    static let accessibilityFourCommandDiameter: CGFloat = 220
    static let minimumPreferredDiameter: CGFloat = 180
    static let maximumPreferredDiameter: CGFloat = 220
    static let minimumCompactDiameter: CGFloat = 148
    static let minimumFourCommandCompactDiameter: CGFloat = 156
    static let minimumTargetSize: CGFloat = 44
    static let edgeMargin: CGFloat = 12
    static let minimumHubClearance: CGFloat = 4
    static let minimumAdjacentClearance: CGFloat = 8

    let commands: [Command]
    let safeRect: CGRect
    let diameter: CGFloat
    let hubDiameter: CGFloat
    let itemDiameter: CGFloat
    let orbitRadius: CGFloat
    /// Clamped center of the radial menu in window coordinates.
    let center: CGPoint

    var radius: CGFloat { diameter / 2 }

    var menuFrame: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)
    }

    var hubFrame: CGRect {
        CGRect(x: center.x - hubDiameter / 2, y: center.y - hubDiameter / 2,
               width: hubDiameter, height: hubDiameter)
    }

    init(containerSize: CGSize, safeAreaInsets: EdgeInsets, anchor: CGPoint?,
         includesAudio: Bool = false, isAccessibilityTextSize: Bool = false) {
        let minX = safeAreaInsets.leading
        let maxX = max(minX, containerSize.width - safeAreaInsets.trailing)
        let minY = safeAreaInsets.top
        let maxY = max(minY, containerSize.height - safeAreaInsets.bottom)
        let safeRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        self.init(safeRect: safeRect, anchor: anchor, includesAudio: includesAudio, isAccessibilityTextSize: isAccessibilityTextSize)
    }

    init(safeRect: CGRect, anchor: CGPoint?, includesAudio: Bool = false, isAccessibilityTextSize: Bool = false) {
        let commands: [Command] = includesAudio ? [.options, .audio, .keyboard, .close] : [.options, .keyboard, .close]
        self.commands = commands
        self.safeRect = safeRect

        let isFour = commands.count == 4
        let desired = isFour
            ? (isAccessibilityTextSize ? Self.accessibilityFourCommandDiameter : Self.preferredFourCommandDiameter)
            : (isAccessibilityTextSize ? Self.accessibilityDiameter : Self.preferredDiameter)
        let minCompact = isFour ? Self.minimumFourCommandCompactDiameter : Self.minimumCompactDiameter
        let hubRatio: CGFloat = isFour ? 0.22 : 0.235
        let itemRatio: CGFloat = isFour ? 0.295 : 0.315

        let insetRect: CGRect
        let resolvedDiameter: CGFloat
        if safeRect.width > 0, safeRect.height > 0 {
            let insetX = min(Self.edgeMargin, max(0, (safeRect.width - minCompact) / 2))
            let insetY = min(Self.edgeMargin, max(0, (safeRect.height - minCompact) / 2))
            insetRect = safeRect.insetBy(dx: insetX, dy: insetY)
            let availableMin = min(insetRect.width, insetRect.height)
            resolvedDiameter = max(minCompact, min(desired, availableMin))
        } else {
            insetRect = safeRect
            resolvedDiameter = desired
        }

        let radius = resolvedDiameter / 2
        let ringPadding = max(4, (resolvedDiameter * 0.04).rounded())
        let hubDiameter = max(Self.minimumTargetSize, (resolvedDiameter * hubRatio).rounded())
        let maxItemForHubClearance = (radius - ringPadding - hubDiameter / 2 - Self.minimumHubClearance).rounded(.down)
        let sinHalfStep = sin(.pi / CGFloat(commands.count))
        let maxItemForAngularClearance = ((2 * sinHalfStep * (radius - ringPadding) - Self.minimumAdjacentClearance) / (1 + sinHalfStep)).rounded(.down)
        let maxItemForClearance = min(maxItemForHubClearance, maxItemForAngularClearance)
        let itemDiameter = max(Self.minimumTargetSize, min((resolvedDiameter * itemRatio).rounded(), maxItemForClearance))
        let orbitRadius = max(radius - ringPadding - itemDiameter / 2, (hubDiameter + itemDiameter) / 2 + Self.minimumHubClearance)

        let target = anchor ?? CGPoint(x: insetRect.maxX - radius, y: insetRect.minY + radius)
        let minCenterX = insetRect.minX + radius
        let maxCenterX = insetRect.maxX - radius
        let minCenterY = insetRect.minY + radius
        let maxCenterY = insetRect.maxY - radius
        let centerX = minCenterX <= maxCenterX ? min(maxCenterX, max(minCenterX, target.x)) : insetRect.midX
        let centerY = minCenterY <= maxCenterY ? min(maxCenterY, max(minCenterY, target.y)) : insetRect.midY

        self.diameter = resolvedDiameter
        self.hubDiameter = hubDiameter
        self.itemDiameter = itemDiameter
        self.orbitRadius = orbitRadius
        self.center = CGPoint(x: centerX, y: centerY)
    }

    /// Polar angle in screen coordinates (0 = right, -π/2 = top, +π/2 = bottom).
    func angle(for command: Command) -> CGFloat {
        if commands.count == 4 {
            switch command {
            case .options: -.pi / 2          // 12 o'clock
            case .audio: 0                   // 3 o'clock
            case .close: .pi / 2             // 6 o'clock
            case .keyboard: .pi              // 9 o'clock
            }
        } else {
            switch command {
            case .options: -.pi / 2          // 12 o'clock
            case .audio: 0                   // unused in 3-command layout
            case .keyboard: 5 * .pi / 6      // 8 o'clock
            case .close: .pi / 6             // 4 o'clock
            }
        }
    }

    func offset(for command: Command) -> CGSize {
        let theta = angle(for: command)
        return CGSize(width: cos(theta) * orbitRadius, height: sin(theta) * orbitRadius)
    }

    func center(for command: Command) -> CGPoint {
        let delta = offset(for: command)
        return CGPoint(x: center.x + delta.width, y: center.y + delta.height)
    }

    func frame(for command: Command) -> CGRect {
        let point = center(for: command)
        return CGRect(x: point.x - itemDiameter / 2, y: point.y - itemDiameter / 2,
                      width: itemDiameter, height: itemDiameter)
    }
}

@MainActor
private enum RadialHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat = 0.7) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred(intensity: intensity)
    }
}

enum RadialControlStyle: Equatable {
    case command
    case destructiveCommand
    case dismissHub
}

/// A native Liquid Glass session control. Every radial item is a UIKit glass
/// button because `UIControl` reports the whole press (touch, mouse or
/// trackpad: touch-down to touch-up or cancel), while SwiftUI's glass button
/// styles report neither presses nor, for `Menu`, its opening; automatic
/// dismissal must wait for both, without adding any gesture recognizer.
class SessionToolbarControl: UIButton {
    private(set) weak var toolbar: SessionToolbar?
    /// Circular hit testing prevents corner overlap inside the compact radial
    /// layout while keeping standalone button frames rectangular by default.
    var usesCircularHitRegion = false
    /// Supplied by the owning radial container so a two-finger gesture cannot
    /// inadvertently activate a single-finger command.
    var radialMultiTouchInProgress: (() -> Bool)?
    /// SF Symbol name applied by `configureRadialAppearance`.
    private(set) var radialSymbolName: String?
    private(set) var sawMultiTouch = false
    private var isPressing = false {
        didSet { if oldValue != isPressing { toolbar?.setControlPressed(isPressing, control: ObjectIdentifier(self)) } }
    }

    init(toolbar: SessionToolbar?) {
        self.toolbar = toolbar
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        self.configuration = configuration
        isMultipleTouchEnabled = true
        isPointerInteractionEnabled = true
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
        addAction(UIAction { [weak self] _ in self?.isPressing = true }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.isPressing = false }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configureRadialAppearance(title: String?, symbolName: String, style: RadialControlStyle) {
        var config: UIButton.Configuration
        let symbolPointSize: CGFloat
        let symbolWeight: UIImage.SymbolWeight
        switch style {
        case .command:
            config = .glass()
            config.baseForegroundColor = .label
            symbolPointSize = 16
            symbolWeight = .semibold
        case .destructiveCommand:
            config = .prominentGlass()
            config.baseBackgroundColor = .systemRed
            config.baseForegroundColor = .white
            symbolPointSize = 16
            symbolWeight = .semibold
        case .dismissHub:
            config = .clearGlass()
            config.baseForegroundColor = .label
            symbolPointSize = 15
            symbolWeight = .bold
        }
        config.cornerStyle = .capsule
        config.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: symbolWeight)
        )
        config.imagePlacement = .top
        config.imagePadding = title == nil ? 0 : 2
        config.title = title
        config.titleAlignment = .center
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        if title != nil {
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                let base = UIFont.systemFont(ofSize: 10, weight: .semibold)
                outgoing.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: base, maximumPointSize: 11.5)
                return outgoing
            }
        }
        configuration = config
        radialSymbolName = symbolName
        largeContentTitle = title
        largeContentImage = UIImage(systemName: symbolName)
    }

    override func updateConfiguration() {
        super.updateConfiguration()
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.72
        titleLabel?.numberOfLines = 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            sawMultiTouch = false
            isPressing = false // a removed control never keeps a press
        }
    }

    /// Allow the ancestor two-finger double-tap toggle recognizer to begin even
    /// when fingers touch down over a radial button, while preserving UIKit's
    /// default single-tap button protection.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.view !== self,
           let tap = gestureRecognizer as? UITapGestureRecognizer,
           tap.numberOfTouchesRequired == 2,
           tap.numberOfTapsRequired == 2 {
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private static func isMultiTouchDirectEvent(_ event: UIEvent?) -> Bool {
        guard let allTouches = event?.allTouches else { return false }
        var directCount = 0
        for touch in allTouches where touch.type == .direct {
            directCount += 1
            if directCount > 1 { return true }
        }
        return false
    }

    func cancelActiveInteraction() {
        sawMultiTouch = false
        isPressing = false
        cancelTracking(with: nil)
    }

    func handleMultiTouchDetected(with event: UIEvent?) {
        sawMultiTouch = true
        isPressing = false
        cancelTracking(with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if Self.isMultiTouchDirectEvent(event) || radialMultiTouchInProgress?() == true {
            handleMultiTouchDetected(with: event)
            super.touchesCancelled(touches, with: event)
            return
        }
        sawMultiTouch = false
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if sawMultiTouch || Self.isMultiTouchDirectEvent(event) || radialMultiTouchInProgress?() == true {
            handleMultiTouchDetected(with: event)
            super.touchesCancelled(touches, with: event)
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if sawMultiTouch || Self.isMultiTouchDirectEvent(event) || radialMultiTouchInProgress?() == true {
            handleMultiTouchDetected(with: event)
            sawMultiTouch = false
            super.touchesCancelled(touches, with: event)
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sawMultiTouch = false
        isPressing = false
        super.touchesCancelled(touches, with: event)
    }

    /// Hidden controls (also while their removal animates): touches and clicks
    /// pass through to the desktop.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard toolbar?.isVisible != false, super.point(inside: point, with: event) else { return false }
        guard usesCircularHitRegion, bounds.width > 0, bounds.height > 0 else { return true }
        let rx = bounds.width / 2, ry = bounds.height / 2
        let dx = (point.x - bounds.midX) / rx
        let dy = (point.y - bounds.midY) / ry
        return dx * dx + dy * dy <= 1
    }
}

/// Radial command actions: Keyboard and Close.
final class SessionActionButton: SessionToolbarControl {
    var action: () -> Void = {}

    override init(toolbar: SessionToolbar?) {
        super.init(toolbar: toolbar)
        addAction(UIAction { [weak self] _ in
            guard let self, !self.sawMultiTouch, self.radialMultiTouchInProgress?() != true else { return }
            RadialHaptics.impact(.light, intensity: 0.7)
            self.toolbar?.controlUsed()
            self.action()
        }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Central hub of the radial menu: dismisses the controls locally without
/// forwarding any touch or click to the remote Mac.
final class SessionDismissButton: SessionToolbarControl {
    var onDismiss: () -> Void = {}

    override init(toolbar: SessionToolbar?) {
        super.init(toolbar: toolbar)
        configureRadialAppearance(title: nil, symbolName: "xmark", style: .dismissHub)
        accessibilityLabel = String(localized: "Dismiss session controls")
        accessibilityHint = String(localized: "Hides the session controls without affecting the remote Mac.")
        accessibilityIdentifier = "radial.dismiss"
        largeContentTitle = String(localized: "Dismiss")
        addAction(UIAction { [weak self] _ in
            guard let self, !self.sawMultiTouch, self.radialMultiTouchInProgress?() != true else { return }
            RadialHaptics.impact(.light, intensity: 0.6)
            self.onDismiss()
        }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The session options menu (display mode, Fit, local pan, input mode and,
/// for a live session, the clipboard commands):
/// UIKit reports when the menu opens and closes, which SwiftUI's `Menu` does not.
final class SessionMenuControl: SessionToolbarControl {
    private weak var controller: SessionController?
    private var shown: (profile: DisplayProfile, pan: Bool, trackpad: Bool,
                        clipboard: Bool, clipboardReady: Bool, clipboardAutomatic: Bool)?

    init(controller: SessionController) {
        self.controller = controller
        super.init(toolbar: controller.toolbar)
        showsMenuAsPrimaryAction = true
        accessibilityLabel = String(localized: "Options")
        accessibilityHint = String(localized: "Opens display, fit and input options.")
        accessibilityIdentifier = "radial.options"
        configureRadialAppearance(title: String(localized: "Options"), symbolName: "gearshape", style: .command)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Menu follows the controller (observed through `updateUIView`).
    /// Unrelated view updates never replace a menu that may be open.
    func refresh() {
        guard let c = controller else { return }
        let clipboard = c.clipboard
        let state = (profile: c.profile, pan: c.panEnabled, trackpad: c.trackpad, clipboard: clipboard != nil,
                     clipboardReady: clipboard?.isAuthorized == true, clipboardAutomatic: clipboard?.automaticSync == true)
        if let shown, shown == state { return }
        shown = state
        let used: @MainActor () -> Void = { [weak c] in c?.toolbar.controlUsed() }
        let profiles = DisplayProfile.allCases.map { profile in
            UIAction(title: profile.rawValue, state: c.profile == profile ? .on : .off) { [weak c] _ in
                used()
                c?.setProfile(profile)
            }
        }
        let fit = UIAction(
            title: String(localized: "Fit"),
            image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        ) { [weak c] _ in
            used()
            c?.fit()
        }
        let pan = UIAction(title: String(localized: "Local pan (one finger)"), state: c.panEnabled ? .on : .off) { [weak c] _ in
            used(); c?.panEnabled.toggle()
        }
        let input = UIMenu(title: String(localized: "Input"),
                           subtitle: c.trackpad ? String(localized: "Trackpad") : String(localized: "Direct"),
                           options: .singleSelection, children: [
            UIAction(title: String(localized: "Trackpad"), state: c.trackpad ? .on : .off) { [weak c] _ in used(); c?.trackpad = true },
            UIAction(title: String(localized: "Direct"), state: c.trackpad ? .off : .on) { [weak c] _ in used(); c?.trackpad = false },
        ])
        var children: [UIMenuElement] = profiles + [fit, pan, input]
        if state.clipboard {
            // Live sessions only: direction is explicit for both manual commands.
            let ready: UIMenuElement.Attributes = state.clipboardReady ? [] : .disabled
            children.append(UIMenu(title: String(localized: "Clipboard"), image: UIImage(systemName: "doc.on.clipboard"), children: [
                UIAction(title: String(localized: "Send Clipboard to Mac…"), attributes: ready) { [weak c] _ in
                    used(); c?.presentClipboardSend()
                },
                UIAction(title: String(localized: "Get Mac Clipboard"), attributes: ready) { [weak c] _ in
                    used(); c?.receiveClipboard()
                },
                UIAction(title: String(localized: "Sync Automatically"), state: state.clipboardAutomatic ? .on : .off) { [weak c] _ in
                    used(); c?.setClipboardAutomaticSync(!state.clipboardAutomatic)
                },
            ]))
        }
        menu = UIMenu(children: children)
    }

    override func cancelActiveInteraction() {
        super.cancelActiveInteraction()
        contextMenuInteraction?.dismissMenu()
    }

    override func handleMultiTouchDetected(with event: UIEvent?) {
        super.handleMultiTouchDetected(with: event)
        contextMenuInteraction?.dismissMenu()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !sawMultiTouch, radialMultiTouchInProgress?() != true else { return nil }
        return super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        controller?.toolbar.setMenuOpen(true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        controller?.toolbar.setMenuOpen(false)
    }

    /// The radial menu appeared: VoiceOver moves to its primary control.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: self)
        }
    }
}

/// Coordinates local radial dismissal gestures on the lowest common UIKit
/// ancestor of `DesktopView` and `RadialMenuContainerView`, without blocking
/// remote drag, pan, pinch, scroll, or hover gestures on `DesktopView`.
@MainActor
final class SessionRadialGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private(set) weak var toolbar: SessionToolbar?
    private(set) weak var desktopView: DesktopView?
    private(set) weak var radialContainer: RadialMenuContainerView?
    private(set) weak var hostView: UIView?

    /// Single tap outside the radial menu: consumes the tap locally and
    /// prevents `DesktopView`'s remote single-tap / hardware click while
    /// leaving drags, pinches, pans, scrolls, and long-presses unblocked.
    let outsideDismissTap: UITapGestureRecognizer
    /// Two-finger double tap on the common ancestor: toggles the visible
    /// radial controls reliably whether fingers land on `DesktopView`, over
    /// radial buttons, or straddling the radial boundary.
    let radialTwoFingerDoubleTap: UITapGestureRecognizer

    var isTrackingMultiTouch: Bool {
        radialTwoFingerDoubleTap.numberOfTouches >= 2
    }

    init(toolbar: SessionToolbar, desktopView: DesktopView?, radialContainer: RadialMenuContainerView) {
        self.toolbar = toolbar
        self.desktopView = desktopView
        self.radialContainer = radialContainer
        outsideDismissTap = UITapGestureRecognizer()
        radialTwoFingerDoubleTap = UITapGestureRecognizer()
        super.init()

        outsideDismissTap.addTarget(self, action: #selector(handleOutsideDismissTap(_:)))
        outsideDismissTap.numberOfTouchesRequired = 1
        outsideDismissTap.numberOfTapsRequired = 1
        outsideDismissTap.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        // Delay `DesktopView.touchesBegan` (hardware mouse / Pencil) until
        // single-tap vs drag resolves; UIKit still delivers touches immediately
        // to `DesktopView`'s pan, pinch, long-press, and scroll recognizers.
        outsideDismissTap.delaysTouchesBegan = true
        outsideDismissTap.cancelsTouchesInView = true
        outsideDismissTap.delegate = self

        radialTwoFingerDoubleTap.addTarget(self, action: #selector(handleTwoFingerDoubleTap(_:)))
        radialTwoFingerDoubleTap.numberOfTouchesRequired = 2
        radialTwoFingerDoubleTap.numberOfTapsRequired = 2
        radialTwoFingerDoubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        radialTwoFingerDoubleTap.delaysTouchesEnded = true
        radialTwoFingerDoubleTap.cancelsTouchesInView = true
        radialTwoFingerDoubleTap.delegate = self
    }

    func attach(to host: UIView, desktopView: DesktopView?) {
        self.desktopView = desktopView
        if hostView === host,
           outsideDismissTap.view === host,
           radialTwoFingerDoubleTap.view === host {
            return
        }
        detach()
        hostView = host
        host.addGestureRecognizer(outsideDismissTap)
        host.addGestureRecognizer(radialTwoFingerDoubleTap)
    }

    func detach() {
        outsideDismissTap.view?.removeGestureRecognizer(outsideDismissTap)
        radialTwoFingerDoubleTap.view?.removeGestureRecognizer(radialTwoFingerDoubleTap)
        hostView = nil
    }

    static func lowestCommonSuperview(_ a: UIView, _ b: UIView?) -> UIView {
        guard let b else { return a }
        var ancestors: Set<ObjectIdentifier> = []
        var cursor: UIView? = a
        while let view = cursor {
            ancestors.insert(ObjectIdentifier(view))
            cursor = view.superview
        }
        cursor = b
        while let view = cursor {
            if ancestors.contains(ObjectIdentifier(view)) {
                return view
            }
            cursor = view.superview
        }
        return a
    }

    @objc private func handleOutsideDismissTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let toolbar, toolbar.canDismiss, !toolbar.isMenuOpen, !toolbar.isControlPressed else { return }
        if let radialContainer, radialContainer.containsInCircle(recognizer.location(in: radialContainer)) {
            return
        }
        RadialHaptics.impact(.light, intensity: 0.6)
        toolbar.dismiss()
    }

    @objc private func handleTwoFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let toolbar, toolbar.canDismiss else { return }
        radialContainer?.cancelActiveInteractions()
        RadialHaptics.impact(.light, intensity: 0.6)
        toolbar.toggle(at: nil)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let toolbar, toolbar.canDismiss else { return false }
        guard let touchView = touch.view else { return false }

        if gestureRecognizer === outsideDismissTap {
            guard !toolbar.isMenuOpen, !toolbar.isControlPressed else { return false }
            guard let desktopView, touchView.isDescendant(of: desktopView) else { return false }
            if let radialContainer, radialContainer.containsInCircle(touch.location(in: radialContainer)) {
                return false
            }
            return true
        }

        if gestureRecognizer === radialTwoFingerDoubleTap {
            let inDesktop = desktopView.map { touchView.isDescendant(of: $0) } ?? false
            let inRadial = radialContainer.map { touchView.isDescendant(of: $0) } ?? false
            return inDesktop || inRadial
        }

        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let toolbar, toolbar.canDismiss else { return false }
        if gestureRecognizer === outsideDismissTap {
            guard !toolbar.isMenuOpen, !toolbar.isControlPressed else { return false }
            if let radialContainer, radialContainer.containsInCircle(gestureRecognizer.location(in: radialContainer)) {
                return false
            }
            return true
        }
        if gestureRecognizer === radialTwoFingerDoubleTap {
            return true
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === outsideDismissTap {
            // Outside single-tap suppresses only `DesktopView`'s remote single-tap
            // click. Pan, pinch, long-press, scroll, hover, and right-click
            // remain unblocked and proceed natively.
            return desktopView.map { otherGestureRecognizer === $0.singleTapRecognizer } ?? false
        }

        if gestureRecognizer === radialTwoFingerDoubleTap {
            if otherGestureRecognizer === outsideDismissTap { return true }
            if let radialContainer, otherGestureRecognizer === radialContainer.ringTapRecognizer { return true }
            if let desktopView {
                if otherGestureRecognizer === desktopView.toolbarToggleRecognizer
                    || otherGestureRecognizer === desktopView.rightTapRecognizer
                    || otherGestureRecognizer === desktopView.singleTapRecognizer {
                    return true
                }
            }
            // Prevent a radial button's immediate menu-presentation recognizer
            // from opening on Tap 1 of a two-finger double tap while preserving
            // normal single-tap activation and long-press Large Content Viewer.
            if let targetView = otherGestureRecognizer.view, Self.isInsideToolbarControl(targetView) {
                if let longPress = otherGestureRecognizer as? UILongPressGestureRecognizer,
                   longPress.minimumPressDuration > 0.1 {
                    return false
                }
                return true
            }
            return false
        }

        return false
    }

    private static func isInsideToolbarControl(_ view: UIView) -> Bool {
        var cursor: UIView? = view
        while let current = cursor {
            if current is SessionToolbarControl { return true }
            cursor = current.superview
        }
        return false
    }
}

/// Circular UIKit container strictly bounded to the radial menu medallion.
/// Owns the radial control subviews (`Options`, optional live `Audio`,
/// `Keyboard`, `Close`, and Center Dismiss), absorbs stray taps on ring gaps
/// between buttons, and leaves every point outside the circular menu
/// completely transparent to `DesktopView`.
final class RadialMenuContainerView: UIView, UIGestureRecognizerDelegate {
    private weak var controller: SessionController?
    private var layout: RadialMenuLayout
    let menuButton: SessionMenuControl
    private(set) var audioButton: AudioMenuControl?
    let keyboardButton: SessionActionButton
    let closeButton: SessionActionButton
    let dismissButton: SessionDismissButton
    let ringTapRecognizer: UITapGestureRecognizer
    private(set) var gestureCoordinator: SessionRadialGestureCoordinator?

    var controls: [SessionToolbarControl] {
        if let audioButton {
            return [menuButton, audioButton, keyboardButton, closeButton, dismissButton]
        }
        return [menuButton, keyboardButton, closeButton, dismissButton]
    }

    init(controller: SessionController, layout: RadialMenuLayout, showsAudio: Bool = false, onClose: @escaping () -> Void) {
        self.controller = controller
        self.layout = layout
        menuButton = SessionMenuControl(controller: controller)
        audioButton = showsAudio ? AudioMenuControl(controller: controller) : nil
        keyboardButton = SessionActionButton(toolbar: controller.toolbar)
        closeButton = SessionActionButton(toolbar: controller.toolbar)
        dismissButton = SessionDismissButton(toolbar: controller.toolbar)
        ringTapRecognizer = UITapGestureRecognizer()
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: layout.diameter, height: layout.diameter)))

        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        isAccessibilityElement = false

        keyboardButton.configureRadialAppearance(
            title: String(localized: "Keyboard"),
            symbolName: "keyboard",
            style: .command
        )
        keyboardButton.accessibilityLabel = String(localized: "Keyboard")
        keyboardButton.accessibilityIdentifier = "radial.keyboard"

        closeButton.configureRadialAppearance(
            title: String(localized: "Close"),
            symbolName: "rectangle.portrait.and.arrow.right",
            style: .destructiveCommand
        )
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityHint = String(localized: "Ends the session.")
        closeButton.accessibilityIdentifier = "radial.close"

        for control in controls {
            control.usesCircularHitRegion = true
            addSubview(control)
        }
        accessibilityElements = controls

        ringTapRecognizer.addTarget(self, action: #selector(handleRingGapTap(_:)))
        ringTapRecognizer.numberOfTouchesRequired = 1
        ringTapRecognizer.numberOfTapsRequired = 1
        ringTapRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        ringTapRecognizer.delegate = self
        addGestureRecognizer(ringTapRecognizer)

        update(controller: controller, layout: layout, showsAudio: showsAudio, onClose: onClose)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(controller: SessionController, layout: RadialMenuLayout, showsAudio: Bool = false, onClose: @escaping () -> Void) {
        self.controller = controller
        let layoutChanged = self.layout != layout
        self.layout = layout
        var controlsChanged = false
        if showsAudio, audioButton == nil {
            let audio = AudioMenuControl(controller: controller)
            audio.usesCircularHitRegion = true
            addSubview(audio)
            audioButton = audio
            controlsChanged = true
        } else if !showsAudio, let audio = audioButton {
            audio.radialMultiTouchInProgress = nil
            audio.removeFromSuperview()
            audioButton = nil
            controlsChanged = true
        }
        if controlsChanged {
            accessibilityElements = controls
        }
        menuButton.refresh()
        audioButton?.refresh()
        keyboardButton.action = { [weak controller] in
            guard let controller else { return }
            controller.keyboardShown.toggle()
            controller.toolbar.dismiss()
        }
        keyboardButton.accessibilityValue = controller.keyboardShown
            ? String(localized: "Shown")
            : String(localized: "Hidden")
        keyboardButton.accessibilityHint = controller.keyboardShown
            ? String(localized: "Hides the on-screen keyboard.")
            : String(localized: "Shows the on-screen keyboard.")
        keyboardButton.accessibilityTraits = controller.keyboardShown ? [.button, .selected] : [.button]
        closeButton.action = onClose
        dismissButton.onDismiss = { [weak toolbar = controller.toolbar] in toolbar?.dismiss() }
        dismissButton.isEnabled = controller.toolbar.canDismiss
        if layoutChanged || controlsChanged {
            setNeedsLayout()
        }
        if window != nil {
            attachGestureCoordinatorIfNeeded()
        }
    }

    func attachGestureCoordinatorIfNeeded() {
        guard window != nil, let controller else { return }
        let coordinator: SessionRadialGestureCoordinator
        if let existing = gestureCoordinator, existing.toolbar === controller.toolbar {
            coordinator = existing
        } else {
            gestureCoordinator?.detach()
            coordinator = SessionRadialGestureCoordinator(
                toolbar: controller.toolbar,
                desktopView: controller.desktopView,
                radialContainer: self
            )
            gestureCoordinator = coordinator
        }
        for control in controls {
            control.radialMultiTouchInProgress = { [weak coordinator] in
                coordinator?.isTrackingMultiTouch == true
            }
        }
        let host = SessionRadialGestureCoordinator.lowestCommonSuperview(self, controller.desktopView)
        coordinator.attach(to: host, desktopView: controller.desktopView)
    }

    func detachGestureCoordinator() {
        gestureCoordinator?.detach()
        gestureCoordinator = nil
        for control in controls {
            control.radialMultiTouchInProgress = nil
        }
    }

    func cancelActiveInteractions() {
        for control in controls {
            control.cancelActiveInteraction()
        }
    }

    func containsInCircle(_ point: CGPoint) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let rx = bounds.width / 2, ry = bounds.height / 2
        let dx = (point.x - bounds.midX) / rx
        let dy = (point.y - bounds.midY) / ry
        return dx * dx + dy * dy <= 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachGestureCoordinatorIfNeeded()
        } else {
            detachGestureCoordinator()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil {
            attachGestureCoordinatorIfNeeded()
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let itemSize = CGSize(width: layout.itemDiameter, height: layout.itemDiameter)
        let hubSize = CGSize(width: layout.hubDiameter, height: layout.hubDiameter)

        func centeredFrame(offset: CGSize, size: CGSize) -> CGRect {
            CGRect(x: center.x + offset.width - size.width / 2,
                   y: center.y + offset.height - size.height / 2,
                   width: size.width, height: size.height)
        }

        menuButton.frame = centeredFrame(offset: layout.offset(for: .options), size: itemSize)
        audioButton?.frame = centeredFrame(offset: layout.offset(for: .audio), size: itemSize)
        keyboardButton.frame = centeredFrame(offset: layout.offset(for: .keyboard), size: itemSize)
        closeButton.frame = centeredFrame(offset: layout.offset(for: .close), size: itemSize)
        dismissButton.frame = centeredFrame(offset: .zero, size: hubSize)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard controller?.toolbar.isVisible == true else { return false }
        return containsInCircle(point)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let toolbar = controller?.toolbar, toolbar.canDismiss else { return false }
        toolbar.dismiss()
        return true
    }

    @objc private func handleRingGapTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let toolbar = controller?.toolbar, toolbar.isVisible else { return }
        toolbar.controlUsed()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === ringTapRecognizer else { return false }
        return touch.view === self && controller?.toolbar.isVisible == true
    }
}

private struct RadialMenuRepresentable: UIViewRepresentable {
    let controller: SessionController
    let layout: RadialMenuLayout
    let showsAudio: Bool
    let onClose: () -> Void
    /// Observed triggers forwarded from SwiftUI so button state stays in sync.
    let profile: DisplayProfile
    let panEnabled: Bool
    let trackpad: Bool
    let keyboardShown: Bool
    let audioState: AudioPipeline.State?
    let audioEnabled: Bool
    let audioMuted: Bool
    let clipboardReady: Bool
    let clipboardAutomatic: Bool
    let canDismiss: Bool

    func makeUIView(context: Context) -> RadialMenuContainerView {
        RadialMenuContainerView(controller: controller, layout: layout, showsAudio: showsAudio, onClose: onClose)
    }

    func updateUIView(_ view: RadialMenuContainerView, context: Context) {
        view.update(controller: controller, layout: layout, showsAudio: showsAudio, onClose: onClose)
    }

    static func dismantleUIView(_ uiView: RadialMenuContainerView, coordinator: ()) {
        uiView.detachGestureCoordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RadialMenuContainerView, context: Context) -> CGSize? {
        CGSize(width: layout.diameter, height: layout.diameter)
    }
}

/// Floating Liquid Glass radial controls overlay: positions around the
/// two-finger double-tap activation point (or upper-trailing safe corner by
/// default), adapts to safe areas, orientation and Dynamic Type, and leaves
/// all points outside the circular menu transparent to `DesktopView`.
struct SessionRadialControlsOverlay: View {
    let controller: SessionController
    var showsAudio = false
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var overlayAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.26, dampingFraction: 0.82)
    }

    private var radialTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.84).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { proxy in
            let safeRect = proxy.frame(in: .global)
            let layout = RadialMenuLayout(
                safeRect: safeRect,
                anchor: controller.toolbar.anchorPoint,
                includesAudio: showsAudio,
                isAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
            )
            let localCenter = CGPoint(
                x: layout.center.x - safeRect.minX,
                y: layout.center.y - safeRect.minY
            )
            ZStack(alignment: .topLeading) {
                Group {
                    if controller.toolbar.isVisible {
                        radialMenu(layout: layout)
                            .transition(radialTransition)
                    }
                }
                .frame(width: layout.diameter, height: layout.diameter)
                .position(x: localCenter.x, y: localCenter.y)
                .animation(overlayAnimation, value: controller.toolbar.isVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: controller.toolbar.isVisible) { oldValue, newValue in
                if !oldValue, newValue, controller.toolbar.stage == .established {
                    RadialHaptics.impact(.light, intensity: 0.7)
                }
            }
        }
    }

    private func radialMenu(layout: RadialMenuLayout) -> some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: layout.diameter, height: layout.diameter)
                .glassEffect(.regular, in: .circle)
                .overlay {
                    Circle()
                        .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 8)
                .allowsHitTesting(false)

            RadialMenuRepresentable(
                controller: controller,
                layout: layout,
                showsAudio: showsAudio,
                onClose: onClose,
                profile: controller.profile,
                panEnabled: controller.panEnabled,
                trackpad: controller.trackpad,
                keyboardShown: controller.keyboardShown,
                audioState: showsAudio ? controller.audioState : nil,
                audioEnabled: showsAudio ? controller.audioEnabled : false,
                audioMuted: showsAudio ? controller.audioMuted : false,
                clipboardReady: controller.clipboard?.isAuthorized == true,
                clipboardAutomatic: controller.clipboard?.automaticSync == true,
                canDismiss: controller.toolbar.canDismiss
            )
            .frame(width: layout.diameter, height: layout.diameter)
        }
        .frame(width: layout.diameter, height: layout.diameter)
        .allowsHitTesting(controller.toolbar.isVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Session controls"))
        .accessibilityHidden(!controller.toolbar.isVisible)
        .accessibilityAction(.escape) {
            controller.toolbar.dismiss()
        }
    }
}
