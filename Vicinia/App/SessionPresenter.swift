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

    /// The controller that presents a session for a request made in `window`:
    /// the top of that window's own presentation chain, never another scene's.
    /// nil when the window is gone or is in the middle of a transition.
    static func presenter(in window: UIWindow?) -> UIViewController? {
        guard let window, window.windowScene != nil, var top = window.rootViewController else { return nil }
        while let p = top.presentedViewController { top = p }
        guard !top.isBeingDismissed, !top.isBeingPresented else { return nil }
        return top
    }

    /// Presents the session over the requesting window. false: nothing was
    /// presented (the caller still owns whatever it reserved for the session).
    @discardableResult
    static func present(_ source: SessionSource, in window: UIWindow?) -> Bool {
        guard let top = presenter(in: window) else { return false }
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
        return top.presentedViewController === host    // UIKit refused it otherwise
    }
}
