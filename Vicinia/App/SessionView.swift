// Vicinia — full-screen session view (Metal desktop and controls).
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

struct SessionView: View {
    let source: SessionSource
    let onClose: () -> Void
    /// Receives `SessionToolbar.prefersPointerLock` (initially and on change).
    let onPointerLockPreference: (Bool) -> Void
    @State private var controller: SessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    @State private var showHUD = true
    #endif

    private static let hintTitle: LocalizedStringResource = "Double-tap with two fingers"
    private static let hintMessage: LocalizedStringResource = "Show or hide the session toolbar at any time."

    /// Overlay-only transition: the desktop surface never moves or resizes.
    private func transition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
    private let overlayAnimation = Animation.easeInOut(duration: 0.2)

    /// `controller` is injectable for tests; production uses a new one per session.
    init(source: SessionSource, controller: SessionController = SessionController(), onClose: @escaping () -> Void,
         onPointerLockPreference: @escaping (Bool) -> Void = { _ in }) {
        self.source = source
        self.onClose = onClose
        self.onPointerLockPreference = onPointerLockPreference
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DesktopSurface(controller: controller, source: source)
                .ignoresSafeArea()
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if showHUD {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.hud, id: \.self) { Text($0) }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 6))
                .padding(8)
                .allowsHitTesting(false)
            }
            #endif
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                ZStack {
                    if controller.toolbar.showsHint {
                        VStack(spacing: 4) {
                            Text(Self.hintTitle).font(.headline)
                            Text(Self.hintMessage).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        .padding()
                        .accessibilityElement(children: .combine)
                        .transition(transition(from: .bottom))
                    }
                }
                .animation(overlayAnimation, value: controller.toolbar.showsHint)
                if let stalled = controller.mediaStalledSeconds {
                    Text("No new picture from the Mac for \(Int(stalled)) s — waiting. The session ends after \(Int(MediaTransport.stallLimitNanos / 1_000_000_000)) s without media.")
                        .font(.caption).padding(8).background(.regularMaterial, in: .capsule).padding()
                } else if source.live != nil, let progress = controller.connectionProgress {
                    Text(progress)
                        .font(.caption).padding(8).background(.regularMaterial, in: .capsule).padding()
                }
                if ![.idle, .disconnecting, .failed].contains(controller.phase), let notice = controller.inputOverflowNotice {
                    Text(notice.message)
                        .font(.caption).padding(8).background(.regularMaterial, in: .capsule).padding()
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            if source.live != nil, let title = controller.terminalTitle {
                VStack(spacing: 10) {
                    Text(title).font(.headline)
                    Text(controller.status).font(.footnote).multilineTextAlignment(.center)
                    Button("Close", action: onClose).buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                if controller.toolbar.isVisible {
                    toolbar.transition(transition(from: .top))
                }
            }
            .animation(overlayAnimation, value: controller.toolbar.isVisible)
        }
        .sheet(item: Bindable(controller).trustPrompt) { prompt in
            HostKeyVerificationView(prompt: prompt) { controller.resolveTrust($0) }
                .interactiveDismissDisabled()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        .onAppear { showHUD = UserDefaults.standard.object(forKey: "hud") == nil || UserDefaults.standard.bool(forKey: "hud") }
        #endif
        .onChange(of: controller.toolbar.showsHint) { _, shown in
            if shown {
                AccessibilityNotification.Announcement("\(String(localized: Self.hintTitle)). \(String(localized: Self.hintMessage))").post()
            }
        }
        .onChange(of: controller.toolbar.prefersPointerLock, initial: true) { _, locked in onPointerLockPreference(locked) }
        .onDisappear { controller.stop() }
    }

    /// Floating, on-demand session controls. Hidden, they leave the hierarchy:
    /// no touch target, accessibility element or visual affordance remains.
    private var toolbar: some View {
        HStack(spacing: 8) {
            SessionMenuButton(controller: controller)
            ToolbarButton(title: String(localized: "Esc"), hint: String(localized: "Sends Escape to the Mac."),
                          toolbar: controller.toolbar) { controller.escape() }
            ToolbarButton(title: String(localized: "Fit"), hint: String(localized: "Shows the whole remote desktop."),
                          toolbar: controller.toolbar) { controller.fit() }
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            ToolbarButton(title: showHUD ? "Hide HUD" : "HUD", hint: "", toolbar: controller.toolbar) { showHUD.toggle() }
            #endif
            ToolbarButton(title: String(localized: "Close"), hint: String(localized: "Ends the session."),
                          toolbar: controller.toolbar, action: onClose)
        }
        .padding(8)
        .allowsHitTesting(controller.toolbar.isVisible) // also while the removal transition runs
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session toolbar")
        .accessibilityHidden(!controller.toolbar.isVisible)
    }
}

/// A native Liquid Glass toolbar control. Every toolbar item is a UIKit glass
/// button because `UIControl` reports the whole press (touch, mouse or
/// trackpad: touch-down to touch-up or cancel), while SwiftUI's glass button
/// styles report neither presses nor, for `Menu`, its opening; automatic
/// dismissal must wait for both, without adding any gesture recognizer.
class SessionToolbarControl: UIButton {
    private(set) weak var toolbar: SessionToolbar?
    private var isPressing = false {
        didSet { if oldValue != isPressing { toolbar?.setControlPressed(isPressing, control: ObjectIdentifier(self)) } }
    }

    init(toolbar: SessionToolbar?) {
        self.toolbar = toolbar
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.buttonSize = .small
        self.configuration = configuration
        isPointerInteractionEnabled = true
        addAction(UIAction { [weak self] _ in self?.isPressing = true }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.isPressing = false }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { isPressing = false } // a removed control never keeps a press
    }

    /// Hidden toolbar (also while its removal animates): touches and clicks
    /// pass through to the desktop.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        toolbar?.isVisible != false && super.point(inside: point, with: event)
    }
}

/// Esc, Fit, Close (and HUD in diagnostic builds).
final class SessionActionButton: SessionToolbarControl {
    var action: () -> Void = {}

    override init(toolbar: SessionToolbar?) {
        super.init(toolbar: toolbar)
        addAction(UIAction { [weak self] _ in
            self?.toolbar?.controlUsed()
            self?.action()
        }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct ToolbarButton: UIViewRepresentable {
    let title: String
    let hint: String
    let toolbar: SessionToolbar
    let action: () -> Void

    func makeUIView(context: Context) -> SessionActionButton { SessionActionButton(toolbar: toolbar) }

    func updateUIView(_ button: SessionActionButton, context: Context) {
        button.action = action
        if button.configuration?.title != title { button.configuration?.title = title }
        button.accessibilityHint = hint.isEmpty ? nil : hint
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SessionActionButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

/// The session menu (display mode, local pan, input mode, keyboard): UIKit
/// reports when the menu opens and closes, which SwiftUI's `Menu` does not.
private struct SessionMenuButton: UIViewRepresentable {
    let controller: SessionController

    func makeUIView(context: Context) -> SessionMenuControl { SessionMenuControl(controller: controller) }

    func updateUIView(_ button: SessionMenuControl, context: Context) { button.refresh() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SessionMenuControl, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

final class SessionMenuControl: SessionToolbarControl {
    private weak var controller: SessionController?
    private var shown: (profile: DisplayProfile, pan: Bool, trackpad: Bool, keyboard: Bool)?

    init(controller: SessionController) {
        self.controller = controller
        super.init(toolbar: controller.toolbar)
        showsMenuAsPrimaryAction = true
        accessibilityHint = String(localized: "Opens display, input and keyboard options.")
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Title and menu follow the controller (observed through `updateUIView`).
    /// Unrelated view updates never replace a menu that may be open.
    func refresh() {
        guard let c = controller else { return }
        let state = (profile: c.profile, pan: c.panEnabled, trackpad: c.trackpad, keyboard: c.keyboardShown)
        if let shown, shown == state { return }
        shown = state
        configuration?.title = c.profile.rawValue
        let used: @MainActor () -> Void = { [weak c] in c?.toolbar.controlUsed() }
        let profiles = DisplayProfile.allCases.map { profile in
            UIAction(title: profile.rawValue) { [weak c] _ in used(); c?.setProfile(profile) }
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
        let keyboard = UIAction(title: String(localized: "Keyboard"), state: c.keyboardShown ? .on : .off) { [weak c] _ in
            used(); c?.keyboardShown.toggle()
        }
        menu = UIMenu(children: profiles + [pan, input, keyboard])
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

    /// The toolbar appeared: VoiceOver moves to its first control.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: self)
        }
    }
}

private struct DesktopSurface: UIViewRepresentable {
    let controller: SessionController
    let source: SessionSource

    func makeUIView(context: Context) -> DesktopView {
        let view = DesktopView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: DesktopView, context: Context) {
        view.panEnabled = controller.panEnabled
        view.trackpad = controller.trackpad
        view.keyboardShown = controller.keyboardShown
        view.toolbarVisible = controller.toolbar.isVisible
        guard !context.coordinator.started else { return }
        context.coordinator.started = true
        let controller = self.controller, source = self.source
        Task { @MainActor in controller.start(source, window: view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var started = false
    }
}

/// First-use host-key verification: the fingerprint comes first and is never truncated.
private struct HostKeyVerificationView: View {
    let prompt: TrustPrompt
    let decide: (Bool) -> Void

    private var groups: [String] {
        stride(from: 0, to: prompt.fingerprint.count, by: 8).map { i in
            let s = prompt.fingerprint.index(prompt.fingerprint.startIndex, offsetBy: i)
            return String(prompt.fingerprint[s ..< prompt.fingerprint.index(s, offsetBy: min(8, prompt.fingerprint.count - i))])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Verify this Mac").font(.title2.bold())
                Text("SHA-256 fingerprint of \(prompt.host)'s RSA identity key:").font(.subheadline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<4, id: \.self) { col in
                                Text(groups[safe: row * 4 + col] ?? "").font(.system(.title3, design: .monospaced).weight(.semibold))
                            }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityLabel(groups.joined(separator: " "))
                Text("Compare it with the fingerprint obtained from the Mac over a trusted channel. Without that comparison this is trust on first use (TOFU). The key is then pinned for this host and any change is refused.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { decide(false) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Trust and Pin") { decide(true) }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
