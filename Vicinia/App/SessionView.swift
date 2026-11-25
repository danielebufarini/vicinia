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
            }
            .allowsHitTesting(false)
        }
        .overlay {
            SessionRadialControlsOverlay(controller: controller, onClose: onClose)
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
