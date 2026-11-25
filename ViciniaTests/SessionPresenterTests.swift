// Vicinia — geometry errors may arrive outside the main executor.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

private enum GeometryTestError: Error { case rejected }

@Suite("Session presentation")
struct SessionPresenterTests {
    @Test("Geometry error callback created on MainActor runs off main")
    @MainActor func geometryErrorOffMain() async {
        let callback: @Sendable (Error) -> Void = SessionPresenter.geometryRequestErrorHandler
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                callback(GeometryTestError.rejected)
                continuation.resume()
            }
        }
    }
}
