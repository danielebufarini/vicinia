// Vicinia — shared remote geometry and view ↔ desktop transformation.
// SPDX-License-Identifier: MIT

import Foundation

enum DisplayProfile: String, CaseIterable, Sendable {
    case retina = "Retina", moreSpace = "More Space"
    var scale: Int { self == .retina ? 2 : 1 }
}

struct DisplayRequest: Equatable, Sendable {
    let backingWidth: Int, backingHeight: Int
    let profile: DisplayProfile
    let proportional: Bool
    var logicalWidth: Int { backingWidth / profile.scale }
    var logicalHeight: Int { backingHeight / profile.scale }

    init(viewportPixels: CGSize, profile: DisplayProfile) {
        let factor = min(1, min(3840 / max(1, viewportPixels.width), 2160 / max(1, viewportPixels.height)))
        backingWidth = max(2, Int(viewportPixels.width * factor) / 2 * 2)
        backingHeight = max(2, Int(viewportPixels.height * factor) / 2 * 2)
        self.profile = profile
        proportional = factor < 1
    }

    var message: [UInt8] {
        RFB.virtualDisplay(logicalWidth: logicalWidth, logicalHeight: logicalHeight, hidpiScale: Double(profile.scale))
    }
    var summary: String {
        "\(profile.rawValue) logical \(logicalWidth)x\(logicalHeight) backing \(backingWidth)x\(backingHeight)"
            + (proportional ? " (proportional host-limit fit)" : "")
    }
}

/// Coordinates from the host's single-display 0x451, never from the request.
struct DesktopGeometry: Equatable, Sendable {
    let logical: CGRect
    let backing: CGRect

    /// macOS 27.2.1 consumes backing pixels (physically verified).
    /// Apply the host's actual logical→backing ratio exactly once, here at the
    /// wire boundary; the shared viewport/cursor transform stays in logical units.
    func wirePoint(fromDesktop point: CGPoint) -> (x: UInt16, y: UInt16) {
        let p = CGPoint(x: backing.minX + (point.x - logical.minX) / logical.width * backing.width,
                        y: backing.minY + (point.y - logical.minY) / logical.height * backing.height)
        return (UInt16(clamping: Int(min(backing.maxX - 1, max(backing.minX, p.x)).rounded())),
                UInt16(clamping: Int(min(backing.maxY - 1, max(backing.minY, p.y)).rounded())))
    }
    var summary: String {
        "logical \(Int(logical.width))x\(Int(logical.height)) origin \(Int(logical.minX)),\(Int(logical.minY))"
            + " backing \(Int(backing.width))x\(Int(backing.height)) origin \(Int(backing.minX)),\(Int(backing.minY))"
    }
}

/// UIKit has already oriented the view and drawable. The same upright transform
/// places backing pixels and maps touches/cursor in logical desktop coordinates.
struct ViewportTransform: Equatable, Sendable {
    let geometry: DesktopGeometry
    let viewport: CGRect                 // useful view points, excluding safe areas
    let zoom: CGFloat
    let pan: CGPoint                     // view points, constrained so every edge is reachable

    init(geometry: DesktopGeometry, viewport: CGRect, zoom: CGFloat = 1, pan: CGPoint = .zero) {
        self.geometry = geometry
        self.viewport = viewport
        self.zoom = min(4, max(1, zoom))
        let fit = min(viewport.width / geometry.backing.width, viewport.height / geometry.backing.height)
        let dx = max(0, (geometry.backing.width * fit * self.zoom - viewport.width) / 2)
        let dy = max(0, (geometry.backing.height * fit * self.zoom - viewport.height) / 2)
        self.pan = CGPoint(x: min(dx, max(-dx, pan.x)), y: min(dy, max(-dy, pan.y)))
    }

    var backingScale: CGFloat {
        min(viewport.width / geometry.backing.width, viewport.height / geometry.backing.height) * zoom
    }
    var desktopRect: CGRect {
        let size = CGSize(width: geometry.backing.width * backingScale, height: geometry.backing.height * backingScale)
        return CGRect(x: viewport.midX - size.width / 2 + pan.x, y: viewport.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }
    func viewPoint(fromDesktop p: CGPoint) -> CGPoint {
        CGPoint(x: desktopRect.minX + (p.x - geometry.logical.minX) / geometry.logical.width * desktopRect.width,
                y: desktopRect.minY + (p.y - geometry.logical.minY) / geometry.logical.height * desktopRect.height)
    }
    func desktopPoint(fromView p: CGPoint) -> CGPoint? {
        guard viewport.contains(p), desktopRect.contains(p) else { return nil }
        return CGPoint(x: geometry.logical.minX + (p.x - desktopRect.minX) / desktopRect.width * geometry.logical.width,
                       y: geometry.logical.minY + (p.y - desktopRect.minY) / desktopRect.height * geometry.logical.height)
    }
}
