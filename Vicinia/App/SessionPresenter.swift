// Vicinia — presents the session full screen from UIKit so that the session
// controller (not SwiftUI's cover controller, which reports portrait only)
// declares every orientation; rotation/viewport changes then reach the view.
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

final class SessionHostingController: UIHostingController<SessionView> {
    /// Requested only while the session is immersive (`SessionToolbar.prefersPointerLock`):
    /// a locked pointer cannot reach the visible toolbar, and its clicks would go to the Mac.
    var pointerLockRequested = false {
        didSet { if oldValue != pointerLockRequested { setNeedsUpdateOfPrefersPointerLocked() } }
    }
    override var prefersPointerLocked: Bool { pointerLockRequested }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

@MainActor
enum SessionPresenter {
    // UIKit may deliver geometry errors outside the main executor.
    static let geometryRequestErrorHandler = { @Sendable (error: Error) in
        print("[vicinia] landscape request: \(error)")
    }

    static func present(_ source: SessionSource) {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        guard let root else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        weak var hostRef: SessionHostingController?
        let host = SessionHostingController(rootView: SessionView(source: source, onClose: {
            hostRef?.dismiss(animated: true)
        }, onPointerLockPreference: { hostRef?.pointerLockRequested = $0 }))
        hostRef = host
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: true) {
            // Start in landscape; geometry follows rotation afterwards.
            host.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.view.window?.windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscapeRight), errorHandler: geometryRequestErrorHandler
            )
        }
    }
}
