// Vicinia — focused protocol, generation and release regression tests.
// SPDX-License-Identifier: MIT
import Foundation
import Testing
import UIKit
import QuartzCore
@testable import Vicinia

@Suite("Cursor and input")
struct InputTests {
    private var geometry: DesktopGeometry {
        DesktopGeometry(logical: CGRect(x: 10, y: 20, width: 100, height: 50),
                        backing: CGRect(x: 20, y: 40, width: 200, height: 100))
    }
    @Test func obsoleteInputRejectedEvenWhenGeometryIsUnchanged() {
        var input = InputState()
        input.activate(geometry)
        let old = input.epoch
        #expect(!input.encode(.key(65, true), epoch: old).isEmpty)
        input.invalidate()
        #expect(input.release() == RFB.key(65, down: false))
        #expect(input.encode(.buttons(.zero, 1), epoch: input.epoch).isEmpty)
        input.activate(geometry)
        #expect(input.encode(.buttons(.zero, 1), epoch: old).isEmpty)
        #expect(input.encode(.key(65, true), epoch: old).isEmpty)
        #expect(input.buttons == 0 && input.keys.isEmpty)
        #expect(!input.encode(.key(66, true), epoch: input.epoch).isEmpty)
    }
    @Test func movesPreserveDragAndReleaseUsesOriginalBackingGeometry() {
        var input = InputState(); input.activate(geometry)
        let e = input.epoch, p = CGPoint(x: 35, y: 30)
        #expect(input.encode(.buttons(p, 1), epoch: e) == RFB.pointer(x: 70, y: 60, buttons: 1))
        #expect(input.encode(.move(CGPoint(x: 40, y: 35)), epoch: e) == RFB.pointer(x: 80, y: 70, buttons: 1))
        _ = input.encode(.key(0xffe7, true), epoch: e)
        _ = input.encode(.key(99, true), epoch: e)
        input.invalidate()
        #expect(input.release() == RFB.pointer(x: 80, y: 70, buttons: 0) + RFB.key(99, down: false) + RFB.key(0xffe7, down: false))
        #expect(input.release().isEmpty)
    }
    @Test func untrustedControlDiscardsHeldStateWithoutSendingReleases() {
        var input = InputState(); input.activate(geometry)
        let old = input.epoch
        _ = input.encode(.buttons(CGPoint(x: 35, y: 30), 1), epoch: old)
        _ = input.encode(.key(0xffeb, true), epoch: old)
        input.discard()
        #expect(input.release().isEmpty)
        #expect(input.buttons == 0 && input.keys.isEmpty && !input.enabled)
        input.activate(geometry)
        #expect(input.encode(.key(65, true), epoch: old).isEmpty)
    }
    /// A pointer-lock handover releases remotely held buttons only.
    /// Held keys (modifiers and ordinary keys) survive it; their key-ups still
    /// arrive afterwards. Empty and obsolete handovers send nothing.
    @Test func pointerReleaseDropsButtonsButKeepsKeys() {
        var input = InputState(); input.activate(geometry)
        let e = input.epoch, p = CGPoint(x: 35, y: 30)
        _ = input.encode(.buttons(p, 1), epoch: e)
        _ = input.encode(.key(0xffeb, true), epoch: e)
        _ = input.encode(.key(97, true), epoch: e)
        #expect(input.encode(.pointerRelease, epoch: e) == RFB.pointer(x: 70, y: 60, buttons: 0))
        #expect(input.buttons == 0 && input.keys == [0xffeb, 97])
        #expect(input.encode(.pointerRelease, epoch: e).isEmpty) // idempotent: no button held
        #expect(input.keys == [0xffeb, 97])
        _ = input.encode(.key(97, false), epoch: e) // the still-held keys release normally
        #expect(input.keys == [0xffeb])
        _ = input.encode(.buttons(p, 1), epoch: e)
        input.invalidate()
        #expect(input.encode(.pointerRelease, epoch: input.epoch).isEmpty) // disabled: gated like every event
        #expect(input.encode(.pointerRelease, epoch: e).isEmpty) // obsolete epoch: dropped
        #expect(input.release() == RFB.pointer(x: 70, y: 60, buttons: 0) + RFB.key(0xffeb, down: false))
    }
    @Test func scrollBurstPreservesEveryPulseAndHeldDrag() {
        var input = InputState(); input.activate(geometry)
        let p = CGPoint(x: 35, y: 30), e = input.epoch
        _ = input.encode(.buttons(p, 1), epoch: e)
        let pulse = RFB.pointer(x: 70, y: 60, buttons: 9) + RFB.pointer(x: 70, y: 60, buttons: 1)
        #expect(input.encode(.scroll(p, 8, 3), epoch: e) == pulse + pulse + pulse)
        #expect(input.buttons == 1)
        #expect(input.encode(.scroll(p, 8, 10000), epoch: e).count == 64 * pulse.count)
        input.invalidate()
        #expect(input.release() == RFB.pointer(x: 70, y: 60, buttons: 0))
    }
    @Test func queuedOldInputIsDiscardedBeforeCBCAdvances() throws {
        var input = InputState(); input.activate(geometry)
        let old = input.epoch
        let pending = ControlWrite.input(.buttons(CGPoint(x: 35, y: 30), 1), epoch: old)
        input.invalidate()
        input.activate(geometry) // same geometry, different display/media generation
        let records = try RecordLayer(rekey: OracleVectors.recordRekey, wrapKey: OracleVectors.recordWrapKey)
        #expect(try pending.seal(records: records, input: &input) == nil)
        #expect(records.sendSequence == 0)
        #expect(input.buttons == 0 && input.keys.isEmpty) // queued down never became dispatched
        #expect(try ControlWrite.release.seal(records: records, input: &input) == nil)
        #expect(records.sendSequence == 0) // empty mandatory barrier emits no record
    }
    private func rect(id: UInt32, compressed: [UInt8] = []) -> FramebufferRect {
        var w = ByteWriter(); w.u32(id); w.u32(UInt32(compressed.count)); w.append(compressed)
        return FramebufferRect(x: 1, y: 0, w: 2, h: 1, encoding: 1104, body: w.bytes)
    }
    // Two pixels BGRA plus alpha plane; a real Z_SYNC_FLUSH stream, no Z_FINISH.
    private let compressed: [UInt8] = [0x78,0x9c,0xe2,0x12,0x91,0xfb,0xaf,0x61,0x64,0xf3,0x9f,0xa1,0x01,0x00,0x00,0x00,0xff,0xff]
    @Test func cursorStoreSelectAlphaHotspotAndUnknownSelection() throws {
        var cache = CursorCache()
        try cache.consume(rect(id: 1, compressed: compressed))
        let shape = try #require(cache.selected)
        #expect(shape.bgra == [10,20,30,0,40,50,60,128])
        #expect(shape.hotspot == CGPoint(x: 1, y: 0))
        try cache.consume(rect(id: 123))
        #expect(cache.selected == shape)
        try cache.consume(FramebufferRect(x: 0, y: 0, w: 0, h: 0, encoding: 1104, body: rect(id: 1).body))
        #expect(cache.visible && cache.selected == shape) // SELECT geometry is zeroed by the host
        try cache.consume(rect(id: 1)); #expect(cache.visible && cache.selected == shape)
        for id: UInt32 in 2...70 { try cache.consume(rect(id: id, compressed: compressed)) }
        #expect(cache.images.count == 64 && cache.images[1] == nil)
    }
    @Test func cursorRejectsBombsAndTruncation() {
        var cache = CursorCache()
        #expect(throws: (any Error).self) { try cache.consume(rect(id: 1, compressed: [0,1,2])) }
        let valid = rect(id: 1, compressed: compressed)
        #expect(throws: (any Error).self) {
            try cache.consume(FramebufferRect(x: 0, y: 0, w: 300, h: 1, encoding: 1104, body: valid.body))
        }
        #expect(throws: (any Error).self) {
            try cache.consume(FramebufferRect(x: 0, y: 0, w: 1, h: 1, encoding: 1104, body: valid.body))
        }
    }
    @Test func keyboardMetadataIncludesSecureInputAndRejectsWrongLength() throws {
        var w = ByteWriter(); w.u16(1); w.u32(1); w.u16(3); w.append(Array("ABC".utf8))
        let s = try HostKeyboardStatus(w.bytes)
        #expect(s.source == "ABC" && s.secure)
        #expect(throws: (any Error).self) { try HostKeyboardStatus(Array(w.bytes.dropLast())) }
        #expect(RFB.key(0xff1b, down: true) == [4,1,0,0,0,0,0xff,0x1b])
    }
}

@Suite("Apple input wrapper")
struct AppleInputWireTests {
    @Test func encryptedPointerPreservesBackingCoordinatesAndAppleButtons() throws {
        let key = [UInt8](repeating: 7, count: 16)
        let bytes = RFB.pointer(x: 1184, y: 640, buttons: 4) + RFB.pointer(x: 1184, y: 640, buttons: 0) + RFB.key(65, down: true)
        let wrapped = try AppleInputWire.wrap(bytes, key: key)
        #expect(wrapped.count == 44 && Array(wrapped.prefix(2)) == [0x10,0])
        let down = try Crypto.aesECBDecryptBlock(key: key, block: Array(wrapped[2..<18]))
        let up = try Crypto.aesECBDecryptBlock(key: key, block: Array(wrapped[20..<36]))
        #expect(Array(down.suffix(6)) == [0xff,2,4,0xa0,2,0x80])
        #expect(up[11] == 0)
        #expect(Array(wrapped.suffix(8)) == RFB.key(65, down: true))
    }
}

@MainActor
private final class InputGeometryWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 0, left: 68, bottom: 20, right: 68) }
}

/// Feeds deterministic UIKit samples through the production target/action.
@MainActor
final class PinchSample: UIPinchGestureRecognizer {
    private var sampleState: UIGestureRecognizer.State = .possible
    private var centroid = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override var numberOfTouches: Int { sampleState == .ended ? 1 : 2 }
    override func location(in target: UIView?) -> CGPoint {
        view?.convert(centroid, to: target) ?? centroid
    }
    func send(to view: DesktopView, _ state: UIGestureRecognizer.State, scale: CGFloat = 1, at point: CGPoint) {
        if self.view !== view { view.addGestureRecognizer(self) }
        sampleState = state; self.scale = scale; centroid = point
        _ = view.perform(NSSelectorFromString("pinchChanged:"), with: self)
    }
}

@Suite("Keyboard viewport")
struct KeyboardViewportTests {
    @MainActor @Test func keyboardLayoutExpansionKeepsPhysicalViewportAndDisplayRequest() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = InputGeometryWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 912, height: 420)
        let view = DesktopView(frame: window.bounds)
        var geometry: ViewportGeometry?
        view.onGeometry = { geometry = $0 }
        window.addSubview(view)
        view.layoutSubviews()
        let initial = try #require(geometry)
        view.frame.size.height = 533 // transient height expansion during software keyboard dismissal
        view.layoutSubviews()
        let expanded = try #require(geometry)
        #expect(initial.usefulPixels == expanded.usefulPixels)
        #expect(initial.drawablePixels != expanded.drawablePixels)
        #expect(DisplayRequest(viewportPixels: initial.usefulPixels.size, profile: .retina)
            == DisplayRequest(viewportPixels: expanded.usefulPixels.size, profile: .retina))
        view.removeFromSuperview()
    }
}

@Suite("Touch ownership")
struct TouchOwnershipTests {
    @MainActor @Test func recognizerTakeoverDoesNotReleaseFingerDrag() {
        let view = DesktopView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var releases = 0
        view.onInput = { if case .release = $0 { releases += 1 } }
        let touch = UITouch()
        #expect(touch.type == .direct)
        view.touchesCancelled([touch], with: nil)
        #expect(releases == 0)
        view.cancelInput()
        #expect(releases == 1)
    }
}

@Suite("Local viewport navigation")
struct LocalViewportTests {
    @MainActor private func renderer() throws -> DesktopRenderer {
        let renderer = try DesktopRenderer(layer: CAMetalLayer(), mailbox: DesktopUpdateMailbox(),
                                           stats: RenderStats(), evidence: EvidenceLog())
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 1600, canvasHeight: 800,
                                  pictureWidth: 1600, pictureHeight: 200, cropTop: 0, visibleHeight: 200)
        renderer.shown = DesktopSnapshot(updateSequence: 1, rtpTimestamp: 1, generation: 1, layout: layout,
                                        stripes: [nil, nil, nil, nil], changedStripes: [], newestSubmitNanos: 0)
        renderer.viewportPixels = CGRect(x: 0, y: 0, width: 800, height: 400)
        return renderer
    }

    @MainActor private func withPinch(_ body: (SessionController, DesktopView, DesktopRenderer, PinchSample) throws -> Void) throws {
        let controller = SessionController()
        let view = DesktopView(frame: CGRect(x: 37, y: 53, width: 800, height: 400))
        controller.attach(view)
        defer { controller.stop() }
        let renderer = try #require(controller.renderer)
        let layout = StripeLayout(rule: .codedStack, stripeCount: 4, canvasWidth: 1600, canvasHeight: 800,
                                  pictureWidth: 1600, pictureHeight: 200, cropTop: 0, visibleHeight: 200)
        renderer.shown = DesktopSnapshot(updateSequence: 1, rtpTimestamp: 1, generation: 1, layout: layout,
                                        stripes: [nil, nil, nil, nil], changedStripes: [], newestSubmitNanos: 0)
        renderer.viewportPixels = CGRect(x: 0, y: 0, width: 800, height: 400)
        try body(controller, view, renderer, PinchSample())
    }

    @MainActor private func expectPoint(_ actual: CGPoint, _ expected: CGPoint) {
        #expect(abs(actual.x - expected.x) < 0.00001)
        #expect(abs(actual.y - expected.y) < 0.00001)
    }

    @MainActor @Test(arguments: [CGPoint(x: 400, y: 200), CGPoint(x: 760, y: 200),
                                CGPoint(x: 40, y: 200), CGPoint(x: 400, y: 20), CGPoint(x: 400, y: 380)])
    func pinchKeepsTheRemotePointUnderItsCentroid(_ focal: CGPoint) throws {
        try withPinch { _, view, renderer, pinch in
            let before = try #require(renderer.viewportTransform)
            let remote = try #require(before.desktopPoint(fromView: focal))
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            let after = try #require(renderer.viewportTransform)
            #expect(after.zoom == 2)
            expectPoint(after.viewPoint(fromDesktop: remote), focal)
            expectPoint(try #require(after.desktopPoint(fromView: focal)), remote)
        }
    }

    @MainActor @Test func movingPinchAfterPanZoomsInAndOutWithoutBeginOrEndJumps() throws {
        try withPinch { _, view, renderer, pinch in
            renderer.changeZoom(by: 2)
            renderer.changePan(by: CGPoint(x: 30, y: -20))
            let focal = CGPoint(x: 650, y: 150)
            let before = try #require(renderer.viewportTransform)
            let remote = try #require(before.desktopPoint(fromView: focal))
            pinch.send(to: view, .began, scale: 1.03, at: focal)
            #expect(renderer.viewportTransform == before && pinch.scale == 1)
            let moved = CGPoint(x: 680, y: 170)
            pinch.send(to: view, .changed, scale: 1.25, at: moved)
            #expect(renderer.viewportTransform?.zoom == 2.5 && pinch.scale == 1)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), moved)
            let reversed = CGPoint(x: 640, y: 160)
            pinch.send(to: view, .changed, scale: 0.8, at: reversed)
            #expect(renderer.viewportTransform?.zoom == 2)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), reversed)
            let ended = renderer.viewportTransform
            pinch.send(to: view, .ended, scale: 0.1, at: .zero) // one remaining touch is not a new centroid
            #expect(renderer.viewportTransform == ended)
            let next = CGPoint(x: 200, y: 250)
            let nextRemote = try #require(ended?.desktopPoint(fromView: next))
            pinch.send(to: view, .began, at: next)
            pinch.send(to: view, .changed, scale: 1.1, at: next)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: nextRemote), next)
        }
    }

    @MainActor @Test func repeatedIncrementalPinchAndFit() throws {
        try withPinch { controller, view, renderer, pinch in
            let focal = CGPoint(x: 710, y: 300)
            let remote = try #require(renderer.viewportTransform?.desktopPoint(fromView: focal))
            pinch.send(to: view, .began, at: focal)
            for _ in 0..<20 {
                pinch.send(to: view, .changed, scale: 1.02, at: focal)
                expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
            }
            #expect(abs(renderer.zoom - pow(1.02, 20)) < 0.00001)
            for _ in 0..<20 {
                pinch.send(to: view, .changed, scale: 1 / 1.02, at: focal)
                expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
            }
            #expect(abs(renderer.zoom - 1) < 0.00001)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            controller.fit()
            #expect(renderer.zoom == 1 && renderer.pan == .zero)
            #expect(renderer.viewportTransform?.desktopRect == CGRect(x: 0, y: 0, width: 800, height: 400))
        }
    }

    @MainActor @Test func pinchZoomLimitsReverseImmediately() throws {
        try withPinch { _, view, renderer, pinch in
            let focal = CGPoint(x: 760, y: 380)
            let remote = try #require(renderer.viewportTransform?.desktopPoint(fromView: focal))
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 100, at: focal)
            #expect(renderer.zoom == 4)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
            let maximum = renderer.viewportTransform
            pinch.send(to: view, .changed, scale: 100, at: focal)
            #expect(renderer.viewportTransform == maximum)
            pinch.send(to: view, .changed, scale: 0.9, at: focal)
            #expect(renderer.zoom == 3.6)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
            pinch.send(to: view, .changed, scale: 0.001, at: focal)
            #expect(renderer.zoom == 1 && renderer.pan == .zero)
            pinch.send(to: view, .changed, scale: 0.5, at: focal)
            #expect(renderer.zoom == 1 && renderer.pan == .zero)
            pinch.send(to: view, .changed, scale: 1.1, at: focal)
            #expect(renderer.zoom == 1.1)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
        }
    }

    @MainActor @Test func movingPinchAtPanBoundsDoesNotAccumulateInvisibleTranslation() throws {
        try withPinch { _, view, renderer, pinch in
            let center = CGPoint(x: 400, y: 200)
            pinch.send(to: view, .began, at: center)
            pinch.send(to: view, .changed, scale: 2, at: center)
            pinch.send(to: view, .changed, at: CGPoint(x: 10000, y: 10000))
            #expect(renderer.pan == CGPoint(x: 400, y: 200))
            pinch.send(to: view, .changed, at: CGPoint(x: 9990, y: 9990))
            #expect(renderer.pan == CGPoint(x: 390, y: 190))
            pinch.send(to: view, .changed, at: CGPoint(x: -10000, y: -10000))
            #expect(renderer.pan == CGPoint(x: -400, y: -200))
            pinch.send(to: view, .changed, at: CGPoint(x: -9990, y: -9990))
            #expect(renderer.pan == CGPoint(x: -390, y: -190))
        }
    }

    @MainActor @Test func zoomOutClampsAndReversesFromTheVisiblePan() throws {
        try withPinch { _, view, renderer, pinch in
            renderer.changeZoom(by: 2)
            renderer.changePan(by: CGPoint(x: 10000, y: 10000))
            let focal = CGPoint(x: 760, y: 380)
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 0.75, at: focal)
            #expect(renderer.zoom == 1.5 && renderer.pan == CGPoint(x: 200, y: 100))
            let visibleRemote = try #require(renderer.viewportTransform?.desktopPoint(fromView: focal))
            pinch.send(to: view, .changed, scale: 1.1, at: focal)
            expectPoint(renderer.pan, CGPoint(x: 184, y: 92))
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: visibleRemote), focal)
        }
    }

    @MainActor @Test func pinchUsesLocalPointsWithSafeAreasLetterboxingAndRotation() throws {
        try withPinch { _, view, renderer, pinch in
            renderer.displayScale = 3
            renderer.viewportPixels = CGRect(x: 204, y: 33, width: 2328, height: 1200)
            let focal = CGPoint(x: 800, y: 350)
            let fit = try #require(renderer.viewportTransform)
            #expect(fit.viewport == CGRect(x: 68, y: 11, width: 776, height: 400))
            #expect(fit.desktopRect.minY == 17) // 6pt vertical letterbox
            let remote = try #require(fit.desktopPoint(fromView: focal))
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), focal)
            renderer.viewportPixels = CGRect(x: 0, y: 0, width: 1200, height: 2400)
            let visible = try #require(renderer.viewportTransform)
            #expect(visible.pan.y == 0)
            let current = CGPoint(x: 810, y: 340)
            pinch.send(to: view, .changed, at: current)
            expectPoint(renderer.pan, CGPoint(x: visible.pan.x + 10, y: 0))
            pinch.send(to: view, .ended, at: .zero)
            let portraitFocal = CGPoint(x: 300, y: 400)
            let portraitRemote = try #require(renderer.viewportTransform?.desktopPoint(fromView: portraitFocal))
            pinch.send(to: view, .began, at: portraitFocal)
            pinch.send(to: view, .changed, scale: 1.2, at: portraitFocal)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: portraitRemote), portraitFocal)
        }
    }

    @MainActor @Test(arguments: [1, 2])
    func pinchPreservesLogicalAndWireMappingAcrossDisplayGenerations(_ remoteScale: Int) throws {
        try withPinch { _, view, renderer, pinch in
            var layout = try #require(renderer.shown).layout
            layout.geometry = DesktopGeometry(logical: CGRect(x: 10, y: 20, width: CGFloat(1600 / remoteScale), height: CGFloat(800 / remoteScale)),
                                              backing: CGRect(x: 20, y: 40, width: 1600, height: 800))
            renderer.shown = DesktopSnapshot(updateSequence: 2, rtpTimestamp: 2, generation: 2, layout: layout,
                                            stripes: [nil, nil, nil, nil], changedStripes: [], newestSubmitNanos: 0)
            let focal = CGPoint(x: 720, y: 320)
            let before = try #require(renderer.viewportTransform)
            let remote = try #require(before.desktopPoint(fromView: focal))
            let wire = before.geometry.wirePoint(fromDesktop: remote)
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            let after = try #require(renderer.viewportTransform)
            let mapped = try #require(after.desktopPoint(fromView: focal))
            expectPoint(mapped, remote)
            expectPoint(after.viewPoint(fromDesktop: remote), focal) // renderer/cursor use the same transform
            var input = InputState(); input.activate(after.geometry)
            #expect(input.encode(.buttons(mapped, 1), epoch: input.epoch) == RFB.pointer(x: wire.x, y: wire.y, buttons: 1))
            #expect(renderer.shown?.generation == 2)
        }
    }

    @MainActor @Test func pinchStartingInLetterboxRemainsBoundedAndContinuous() throws {
        try withPinch { _, view, renderer, pinch in
            renderer.viewportPixels = CGRect(x: 0, y: 0, width: 400, height: 800)
            let focal = CGPoint(x: 300, y: 100)
            #expect(renderer.viewportTransform?.desktopPoint(fromView: focal) == nil)
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            #expect(renderer.zoom == 2 && renderer.pan == CGPoint(x: -100, y: 0))
            pinch.send(to: view, .changed, scale: 0.5, at: focal)
            #expect(renderer.zoom == 1 && renderer.pan == .zero)
        }
    }

    @MainActor @Test func pinchRebasesAfterKeyboardOrOrientationGeometryCancellation() throws {
        try withPinch { _, view, renderer, pinch in
            let focal = CGPoint(x: 650, y: 150)
            pinch.send(to: view, .began, at: focal)
            pinch.send(to: view, .changed, scale: 2, at: focal)
            view.onGeometry?(ViewportGeometry(boundsPoints: CGSize(width: 400, height: 800), displayScale: 2,
                                              safeArea: .zero, drawablePixels: CGSize(width: 800, height: 1600),
                                              interfaceOrientation: "portrait", maximumFramesPerSecond: 60))
            let current = CGPoint(x: 300, y: 400)
            let remote = try #require(renderer.viewportTransform?.desktopPoint(fromView: current))
            pinch.send(to: view, .changed, scale: 1.1, at: current)
            expectPoint(try #require(renderer.viewportTransform).viewPoint(fromDesktop: remote), current)
            for state in [UIGestureRecognizer.State.cancelled, .failed] {
                let before = renderer.viewportTransform
                pinch.send(to: view, state, scale: 3, at: .zero)
                pinch.send(to: view, .began, at: current)
                #expect(renderer.viewportTransform == before)
            }
        }
    }

    @MainActor @Test func panStartsAtTheVisibleOffsetAfterGeometryChanges() throws {
        let renderer = try renderer()
        renderer.changeZoom(by: 2)
        renderer.changePan(by: CGPoint(x: 300, y: 150))
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 300, y: 150))
        renderer.viewportPixels = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 200, y: 100))
        renderer.changePan(by: CGPoint(x: -10, y: -10))
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 190, y: 90))
        // Rotation clamps the short axis, then a reverse drag must move immediately.
        renderer.viewportPixels = CGRect(x: 0, y: 0, width: 200, height: 400)
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 100, y: 0))
        renderer.changePan(by: CGPoint(x: -10, y: 10))
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 90, y: 0))
    }

    @MainActor @Test func zoomPanBoundsMappingAndFit() throws {
        let renderer = try renderer()
        renderer.changeZoom(by: 2)
        renderer.changePan(by: CGPoint(x: 30, y: -20))
        let t = try #require(renderer.viewportTransform)
        #expect(t.pan == CGPoint(x: 30, y: -20))
        let center = CGPoint(x: 400, y: 200)
        let logical = try #require(t.desktopPoint(fromView: center))
        #expect(t.viewPoint(fromDesktop: logical) == center)
        renderer.changePan(by: CGPoint(x: 10000, y: -10000))
        #expect(renderer.viewportTransform?.pan == CGPoint(x: 400, y: -200))
        renderer.fit()
        #expect(renderer.viewportTransform?.zoom == 1)
        #expect(renderer.viewportTransform?.pan == .zero)
        #expect(renderer.viewportTransform?.desktopRect == CGRect(x: 0, y: 0, width: 800, height: 400))
    }

    @MainActor private final class PanSample: UIPanGestureRecognizer {
        var sampleState: UIGestureRecognizer.State = .changed
        var delta = CGPoint(x: 20, y: 40)
        var fingers = 1
        override var state: UIGestureRecognizer.State {
            get { sampleState }
            set { sampleState = newValue }
        }
        override var numberOfTouches: Int { fingers }
        override func translation(in view: UIView?) -> CGPoint { delta }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) { delta = translation }
    }

    @MainActor @Test func localPanDoesNotDispatchRemoteInputAndModeSwitchReleasesDrag() {
        let view = DesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        var remote: [String] = [], offsets: [CGPoint] = []
        view.onInput = { event in
            switch event {
            case .relative: remote.append("move")
            case .button: remote.append("button")
            case .wheel: remote.append("wheel")
            case .release: remote.append("release")
            default: remote.append("other")
            }
        }
        view.onPan = { offsets.append($0) }
        let gesture = PanSample()
        func move(_ state: UIGestureRecognizer.State = .changed, fingers: Int = 1) {
            gesture.sampleState = state; gesture.fingers = fingers
            gesture.delta = CGPoint(x: 20, y: 40)
            _ = view.perform(NSSelectorFromString("moved:"), with: gesture)
        }
        view.trackpad = false
        move(.began)
        #expect(remote == ["release", "button"])
        view.panEnabled = true
        #expect(remote == ["release", "button", "release"])
        remote.removeAll()
        move(.began); move(); move(fingers: 2)
        #expect(remote.isEmpty)
        #expect(offsets == [CGPoint(x: 20, y: 40), CGPoint(x: 20, y: 40)])
        view.panEnabled = false
        #expect(remote == ["release"])
        remote.removeAll()
        view.trackpad = true
        move()
        #expect(remote == ["release", "move"])
        remote.removeAll()
        move(fingers: 2)
        #expect(!remote.isEmpty && remote.allSatisfy { $0 == "wheel" })
        view.trackpad = false
        remote.removeAll()
        move(.began)
        #expect(remote == ["button"])
    }

}
