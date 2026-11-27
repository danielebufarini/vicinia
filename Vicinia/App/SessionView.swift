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
    private static let hintMessage: LocalizedStringResource = "Show or hide the session controls at any time."

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
                if source.live != nil, controller.phase == .streaming, let state = controller.audioState, state.needsAttention {
                    Text(state.notice)
                        .font(.caption).padding(8).background(.regularMaterial, in: .capsule).padding()
                }
                if source.live != nil, ![.idle, .disconnecting, .failed].contains(controller.phase),
                   let notice = controller.clipboard?.notice {
                    Text(notice.message)
                        .font(.caption).multilineTextAlignment(.center)
                        .padding(8).background(.regularMaterial, in: .capsule).padding()
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            SessionRadialControlsOverlay(controller: controller, showsAudio: source.live != nil, onClose: onClose)
        }
        #if DEBUG && VICINIA_DEVELOPER_TOOLS
        .overlay(alignment: .topLeading) {
            ZStack {
                if controller.toolbar.isVisible {
                    Button(showHUD ? "Hide HUD" : "HUD") {
                        controller.toolbar.controlUsed()
                        showHUD.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
                    .transition(transition(from: .top))
                }
            }
            .animation(overlayAnimation, value: controller.toolbar.isVisible)
        }
        #endif
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
        .sheet(isPresented: Bindable(controller).clipboardSendShown) {
            ClipboardSendPanel(onPaste: { controller.sendClipboard($0) }, onCancel: { controller.clipboardSendShown = false })
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
        .onChange(of: controller.clipboard?.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.message).post() }
        }
        .onChange(of: controller.toolbar.prefersPointerLock, initial: true) { _, locked in onPointerLockPreference(locked) }
        .onDisappear { controller.stop() }
    }
}

extension AudioPipeline.State {
    /// Compact, non-color-only status badge shown on the radial Audio control.
    /// Every state uses a distinct SF Symbol glyph in addition to semantic tinting.
    enum StatusBadge: Equatable, Sendable {
        case active
        case negotiating
        case muted
        case inactive
        case attention

        var symbolName: String {
            switch self {
            case .active: "waveform"
            case .negotiating: "ellipsis"
            case .muted: "speaker.slash.fill"
            case .inactive: "minus"
            case .attention: "exclamationmark"
            }
        }

        var backgroundColor: UIColor {
            switch self {
            case .active: .systemGreen
            case .negotiating: .systemGray
            case .muted: .systemIndigo
            case .inactive: .secondaryLabel
            case .attention: .systemOrange
            }
        }

        var foregroundColor: UIColor {
            switch self {
            case .inactive: .systemBackground
            default: .white
            }
        }
    }

    /// Short status for the Audio menu and accessibility value.
    var title: String {
        switch self {
        case .disabled: String(localized: "Off")
        case .negotiating: String(localized: "Waiting for audio from the Mac")
        case .playing: String(localized: "Playing")
        case .muted: String(localized: "Muted")
        case .interrupted(.system): String(localized: "Interrupted")
        case .interrupted(.routeLost): String(localized: "Paused: the audio output was disconnected")
        case .interrupted(.mediaServices): String(localized: "Interrupted: the system audio service restarted")
        case .unavailable: String(localized: "Not available on this device")
        case .failed(let reason): reason
        }
    }

    var statusBadge: StatusBadge {
        switch self {
        case .playing: .active
        case .negotiating: .negotiating
        case .muted: .muted
        case .disabled, .unavailable: .inactive
        case .interrupted, .failed: .attention
        }
    }

    /// Not chosen by the user and not playing: shown even while the session controls are hidden.
    var needsAttention: Bool {
        switch self {
        case .interrupted, .failed: true
        default: false
        }
    }

    var notice: String {
        switch self {
        case .failed(let reason): String(localized: "\(reason) The desktop is not affected.")
        default: String(localized: "Mac audio: \(title). Resume it from Audio in session controls.")
        }
    }

    var canResume: Bool { needsAttention }
}

/// Mac audio: first-class radial command showing state at a glance via a compact
/// non-color-only badge over the `music.note` icon, play/stop (saved for this Mac),
/// mute for this session, and resume after an interruption.
final class AudioMenuControl: SessionToolbarControl {
    private weak var controller: SessionController?
    private var shown: (state: AudioPipeline.State?, enabled: Bool, muted: Bool)?
    let statusBadgeView = UIView()
    private let statusBadgeIconView = UIImageView()
    private(set) var statusBadge: AudioPipeline.State.StatusBadge = .negotiating
    var statusBadgeSymbolName: String { statusBadge.symbolName }

    init(controller: SessionController) {
        self.controller = controller
        super.init(toolbar: controller.toolbar)
        showsMenuAsPrimaryAction = true
        accessibilityLabel = String(localized: "Mac audio")
        accessibilityHint = String(localized: "Opens Mac audio options.")
        accessibilityIdentifier = "radial.audio"
        configureRadialAppearance(title: String(localized: "Audio"), symbolName: "music.note", style: .command)

        statusBadgeView.isUserInteractionEnabled = false
        statusBadgeView.isAccessibilityElement = false
        statusBadgeView.clipsToBounds = true
        statusBadgeView.layer.borderWidth = 1.5
        statusBadgeIconView.isUserInteractionEnabled = false
        statusBadgeIconView.isAccessibilityElement = false
        statusBadgeIconView.contentMode = .scaleAspectFit
        statusBadgeView.addSubview(statusBadgeIconView)
        addSubview(statusBadgeView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.statusBadgeView.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.75).cgColor
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        bringSubviewToFront(statusBadgeView)
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let badgeSize = min(18, max(14, (diameter * 0.29).rounded()))
        let buttonRadius = diameter / 2
        let badgeRadius = badgeSize / 2
        let orbit = max(0, buttonRadius - badgeRadius - 1)
        let angle = -CGFloat.pi / 4
        let badgeCenter = CGPoint(
            x: bounds.midX + cos(angle) * orbit,
            y: bounds.midY + sin(angle) * orbit
        )
        statusBadgeView.frame = CGRect(
            x: badgeCenter.x - badgeRadius,
            y: badgeCenter.y - badgeRadius,
            width: badgeSize,
            height: badgeSize
        )
        statusBadgeView.layer.cornerRadius = badgeRadius
        statusBadgeView.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.75).cgColor
        let iconInset = (badgeSize * 0.22).rounded(.down)
        statusBadgeIconView.frame = statusBadgeView.bounds.insetBy(dx: iconInset, dy: iconInset)
    }

    /// Follows the controller; an unrelated update never replaces an open menu.
    func refresh() {
        guard let c = controller else { return }
        let state = (state: c.audioState, enabled: c.audioEnabled, muted: c.audioMuted)
        if let shown, shown == state { return }
        shown = state
        let current = c.audioState ?? .negotiating
        let badge = current.statusBadge
        statusBadge = badge
        statusBadgeView.backgroundColor = badge.backgroundColor
        statusBadgeIconView.tintColor = badge.foregroundColor
        statusBadgeIconView.image = UIImage(
            systemName: badge.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        )
        configuration?.baseForegroundColor = badge == .inactive ? .secondaryLabel : .label
        accessibilityValue = current.title
        let used: @MainActor () -> Void = { [weak c] in c?.toolbar.controlUsed() }
        var items: [UIMenuElement] = []
        if current.canResume {
            items.append(UIAction(title: String(localized: "Resume Audio")) { [weak c] _ in used(); c?.resumeAudio() })
        }
        let playable = state.state != nil && current != .unavailable
        items.append(UIAction(title: String(localized: "Play Mac Audio"), attributes: playable ? [] : .disabled,
                              state: c.audioEnabled && playable ? .on : .off) { [weak c] _ in
            used()
            if let c { c.setAudioEnabled(!c.audioEnabled) }
        })
        items.append(UIAction(title: String(localized: "Mute"), attributes: c.audioEnabled && playable ? [] : .disabled,
                              state: c.audioMuted ? .on : .off) { [weak c] _ in
            used()
            if let c { c.setAudioMuted(!c.audioMuted) }
        })
        menu = UIMenu(title: String(localized: "Mac Audio: \(current.title)"), children: items)
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

/// Send local: the system paste control hands over what was copied on this
/// device without a paste-permission prompt and without any disguised read.
private struct ClipboardSendPanel: View {
    let onPaste: ([NSItemProvider]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Send Clipboard to Mac").font(.headline)
            Text("Tap Paste to put what you copied on this device on the Mac clipboard. Text, links, formatted text and images can be shared.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            PasteButton(supportedContentTypes: ClipboardFormats.pasteTypes) { providers in onPaste(providers) }
                .labelStyle(.titleAndIcon)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(24)
        .presentationDetents([.medium])
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
