// Vicinia — HPSS desktop renderer: CAMetalLayer + CAMetalDisplayLink.
// SPDX-License-Identifier: MIT
//
// Techniques (re-implemented, no code copied): retained render-source
// snapshots and GPU-completion ownership (CocoaSpice CSMetalRenderer.m,
// Apache-2.0, d8d29fc); plane-specific CVMetalTextureCache mapping and texture
// wrapper retention (MetalPetal MTICVMetalTextureCache.m, MIT core, f9b7889).

import CoreVideo
import Metal
import QuartzCore
import UIKit

/// Keeps decoded pixel buffers and their CVMetalTexture wrappers alive until
/// the GPU finished reading them. Invariant (why @unchecked Sendable is sound):
/// immutable after init and never dereferenced; the command-buffer completion
/// handler merely releases it.
final class GPURetainer: @unchecked Sendable {
    let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}

struct ColorParams {
    var r: SIMD4<Float>
    var g: SIMD4<Float>
    var b: SIMD4<Float>
    var offsets: SIMD4<Float>     // y offset, c offset, y scale, c scale

    static func make(matrix: String?, fullRange: Bool) -> ColorParams {
        // (Kr, Kb) per ITU-R BT.709 / BT.601 / BT.2020; default BT.709
        // when the buffer carries no matrix.
        let (kr, kb): (Float, Float) = switch matrix {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4): (0.299, 0.114)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020): (0.2627, 0.0593)
        default: (0.2126, 0.0722)
        }
        let kg = 1 - kr - kb
        let r = SIMD4<Float>(1, 0, 2 * (1 - kr), 0)
        let g = SIMD4<Float>(1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0)
        let b = SIMD4<Float>(1, 2 * (1 - kb), 0, 0)
        let offsets = fullRange
            ? SIMD4<Float>(0, 128.0 / 255.0, 1, 1)
            : SIMD4<Float>(16.0 / 255.0, 128.0 / 255.0, 255.0 / 219.0, 255.0 / 224.0)
        return ColorParams(r: r, g: g, b: b, offsets: offsets)
    }
}

private struct StripeQuad {
    var dst: SIMD4<Float>
    var src: SIMD4<Float>
}

@MainActor
final class DesktopRenderer: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    let layer: CAMetalLayer
    let mailbox: DesktopUpdateMailbox
    let stats: RenderStats
    private(set) var evidence: EvidenceLog
    /// Useful viewport (safe area) inside the drawable, in pixels.
    var viewportPixels: CGRect = .zero { didSet { needsRedraw = true } }
    var displayScale: CGFloat = 1
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero
    var onPresented: (@Sendable (DesktopPresentation) -> Void)?
    var onVideoPresented: (@Sendable (UInt64, UInt64, UInt32, UInt64) -> Void)?

    var viewportTransform: ViewportTransform? { shown.map { transform(for: $0) } }

    private func transform(for snapshot: DesktopSnapshot) -> ViewportTransform {
        let v = viewportPixels
        return ViewportTransform(geometry: snapshot.layout.desktopGeometry,
                                 viewport: CGRect(x: v.minX / displayScale, y: v.minY / displayScale,
                                                  width: v.width / displayScale, height: v.height / displayScale),
                                 zoom: zoom, pan: pan)
    }

    func changeZoom(by factor: CGFloat, from previous: CGPoint? = nil, to current: CGPoint? = nil) {
        guard let shown else { return }
        let visible = transform(for: shown)
        let center = CGPoint(x: visible.viewport.midX, y: visible.viewport.midY)
        let previous = previous ?? center, current = current ?? previous
        zoom = min(4, max(1, visible.zoom * factor))
        let ratio = zoom / visible.zoom
        // Invert the visible centered scale + pan, then place that same remote
        // point at the new centroid. The affine form also covers letterboxing.
        pan = CGPoint(x: current.x - center.x - (previous.x - center.x - visible.pan.x) * ratio,
                      y: current.y - center.y - (previous.y - center.y - visible.pan.y) * ratio)
        // Persist only the visible bounds, as for pan: reversal is immediate.
        pan = transform(for: shown).pan
        needsRedraw = true
    }

    func changePan(by delta: CGPoint) {
        guard let shown else { return }
        // Geometry may have clamped the visible offset since the previous gesture.
        let visible = transform(for: shown).pan
        pan = CGPoint(x: visible.x + delta.x, y: visible.y + delta.y)
        pan = transform(for: shown).pan
        needsRedraw = true
    }

    func fit() {
        zoom = 1; pan = .zero
        needsRedraw = true
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let cursorPipeline: any MTLRenderPipelineState
    private var cursorTexture: (any MTLTexture)?
    private var cursorImage: CursorImage?
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Cursor movements not yet drawn: the UIKit timestamp of the OLDEST one is
    /// the start of local cursor latency (conservative when several share a frame).
    private var cursorPending: (event: TimeInterval, handled: UInt64, moves: Int)?
    #endif
    private(set) var cursorPoint: CGPoint?
    /// `eventTime`: timestamp of the UIKit event that caused the movement.
    func moveCursor(to point: CGPoint, eventTime: TimeInterval = 0) {
        needsRedraw = true
        guard point != cursorPoint else { return }
        cursorPoint = point
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if cursorPending == nil { cursorPending = (eventTime, DispatchTime.now().uptimeNanoseconds, 1) }
        else { cursorPending?.moves += 1 }
        #endif
    }
    private var cursorVisible = true
    func setCursor(_ image: CursorImage?, visible: Bool) {
        let image = image ?? (visible ? CursorImage.arrow : nil)
        cursorVisible = visible
        guard cursorImage != image else { needsRedraw = true; return }
        cursorImage = image
        cursorTexture = nil
        if let image {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
            d.usage = .shaderRead
            if let t = device.makeTexture(descriptor: d) {
                image.bgra.withUnsafeBytes { p in
                    t.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                              withBytes: p.baseAddress!, bytesPerRow: image.width * 4)
                }
                cursorTexture = t
            }
        }
        needsRedraw = true
    }
    private let cache: CVMetalTextureCache
    private var link: CAMetalDisplayLink?
    // Internal for deterministic viewport tests without running the display link.
    var shown: DesktopSnapshot?
    private var waiting: DesktopSnapshot?
    private var mapped: [ObjectIdentifier: (luma: CVMetalTexture, chroma: CVMetalTexture)] = [:]
    private var color = ColorParams.make(matrix: nil, fullRange: true)
    private var describedGeneration: UInt64?
    private var unsupportedFormat = false
    private var needsRedraw = true
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private var lastTarget: CFTimeInterval = 0
    #endif
    /// Display-link target of the frame that carried the newest desktop (pacing).
    private var lastNewTarget: CFTimeInterval = 0
    /// Measured: UIKit delivers the touches of a refresh just AFTER the
    /// display-link callback of that refresh, so a frame drawn inside the
    /// callback shows the cursor one refresh late. The frame is therefore
    /// drawn `lateDrawNanos` after the callback, once that input has been
    /// handled; it still targets the same presentation.
    static let lateDrawNanos: UInt64 = 2_000_000
    private var pendingFrame: (drawable: any CAMetalDrawable, target: CFTimeInterval)?
    private var lateTimer: (any DispatchSourceTimer)?
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Scripted physical checks only. `-probe "x,y"` (desktop backing pixels):
    /// the luma there is recorded with every drawn update, so a deterministic
    /// host response to an input can be identified in the trace.
    /// `-stall-presentation "start,seconds"` (after `start()`): nothing is
    /// drawn in that window, as if the presentation pipeline had stalled.
    private let probePoint: (x: Int, y: Int)? = {
        let v = (UserDefaults.standard.string(forKey: "probe") ?? "").split(separator: ",").compactMap { Int($0) }
        return v.count == 2 ? (v[0], v[1]) : nil
    }()
    private let stallWindow: ClosedRange<Double>? = {
        let v = (UserDefaults.standard.string(forKey: "stall-presentation") ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? v[0]...(v[0] + v[1]) : nil
    }()
    private var startedAt: CFTimeInterval = 0
    #endif

    init(layer: CAMetalLayer, mailbox: DesktopUpdateMailbox, stats: RenderStats, evidence: EvidenceLog) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { throw RendererError.metalUnavailable }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "stripe_vertex")
        d.fragmentFunction = library.makeFunction(name: "ycbcr444_fragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        d.fragmentFunction = library.makeFunction(name: "cursor_fragment")
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        cursorPipeline = try device.makeRenderPipelineState(descriptor: d)
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess,
              let c else { throw RendererError.textureCache }
        self.device = device
        self.queue = queue
        self.cache = c
        self.layer = layer
        self.mailbox = mailbox
        self.stats = stats
        self.evidence = evidence
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        super.init()
        setCursor(.arrow, visible: true)
        evidence.set("metal.device", device.name)
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    func rebind(evidence: EvidenceLog) {
        self.evidence = evidence
        describedGeneration = nil
    }
    #endif

    func start() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1     // measured: default 2.0 added a refresh of latency
        link.add(to: .main, forMode: .common)
        self.link = link
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        startedAt = CACurrentMediaTime()
        if let w = stallWindow { evidence.set("fault.stallPresentation", "\(w.lowerBound)-\(w.upperBound) s after start") }
        if let p = probePoint { evidence.set("probe.pixel", "\(p.x),\(p.y)") }
        #endif
        evidence.set("presentation.draw", "\(Self.lateDrawNanos / 1_000) µs after the display-link callback (pending input handled first)")
        evidence.set("presentation.path", "CAMetalLayer+CAMetalDisplayLink (main run loop), preferredFrameLatency=\(link.preferredFrameLatency)")
        evidence.set("presentation.pacing", "commit < \(PresentationPacing.holdNanos / 1_000) µs before a tick waits one refresh "
            + "when the previous new desktop targeted the adjacent refresh")
    }

    func stop() {
        link?.invalidate()
        link = nil
        lateTimer?.cancel()
        lateTimer = nil
        pendingFrame = nil
        shown = nil
        waiting = nil
        lastNewTarget = 0
        onPresented = nil
        onVideoPresented = nil
        mapped.removeAll()
        CVMetalTextureCacheFlush(cache, 0)
    }

    // MARK: CAMetalDisplayLinkDelegate (main run loop)

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let target = update.targetPresentationTimestamp
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let last = lastTarget
        lastTarget = target
        #endif
        stats.update { v in
            v.displayTicks += 1
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            if last > 0, v.fresh.refreshIntervals.count < RenderStats.maxFresh { v.fresh.refreshIntervals.append(target - last) }
            #endif
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if let w = stallWindow, w.contains(CACurrentMediaTime() - startedAt) { return }
        #endif
        if pendingFrame != nil { stats.update { $0.lateDrawsMissed += 1 } }    // its deadline has passed: dropped
        pendingFrame = (update.drawable, target)
        if lateTimer == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            t.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let frame = self.pendingFrame else { return }
                    self.pendingFrame = nil
                    self.render(into: frame.drawable, target: frame.target)
                }
            }
            t.schedule(deadline: .distantFuture)
            t.resume()
            lateTimer = t
        }
        lateTimer?.schedule(deadline: .now() + .nanoseconds(Int(Self.lateDrawNanos)), leeway: .microseconds(100))
    }

    private func render(into drawable: any CAMetalDrawable, target: CFTimeInterval) {
        let limit = waiting == nil
            ? PresentationPacing.commitLimit(now: DispatchTime.now().uptimeNanoseconds, target: target, lastNewTarget: lastNewTarget)
            : .max
        if let fresh = mailbox.take(committedBy: limit) {
            if let replaced = waiting {              // taken, never drawn: a lost update, counted as such
                mailbox.note(replaced.timing, .replacedWaiting)
                stats.update { $0.replacedWhileWaiting += 1 }
            }
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            var timed = fresh
            timed.timing.take = DispatchTime.now().uptimeNanoseconds
            waiting = timed
            #else
            waiting = fresh
            #endif
        }
        if let w = waiting, !mailbox.isCurrent(w) {   // reset/disconnect/loss: never new output
            waiting = nil
            mailbox.note(w.timing, .obsolete)
            stats.update { $0.obsoleteSnapshotsDropped += 1 }
        }
        let isNew = waiting != nil
        guard let snapshot = waiting ?? (needsRedraw ? shown : nil) else { return }
        guard stats.inFlight.load(ordering: .acquiring) < 2 else {     // never block: try next refresh
            stats.update { $0.skippedGPUBusy += 1 }
            return
        }
        if draw(snapshot, into: drawable, isNew: isNew, target: target) {
            if isNew { lastNewTarget = target }
            waiting = nil
            shown = snapshot
            needsRedraw = false
        }
    }

    // MARK: Drawing

    private func draw(_ s: DesktopSnapshot, into drawable: any CAMetalDrawable, isNew: Bool, target: CFTimeInterval) -> Bool {
        if describedGeneration != s.generation, let first = s.stripes.compactMap({ $0 }).first {
            describe(first.pixelBuffer, layout: s.layout, generation: s.generation)
        }
        guard !unsupportedFormat else { return false }
        // Never switch to a partial desktop because one texture mapping failed.
        // Pre-map every visible stripe before submitting any work.
        var nextMapped: [ObjectIdentifier: (luma: CVMetalTexture, chroma: CVMetalTexture)] = [:]
        for i in 0..<s.layout.stripeCount where s.layout.placement(stripe: i).rows > 0 {
            guard let stripe = s.stripes[i], let textures = textures(for: stripe.pixelBuffer),
                  CVMetalTextureGetTexture(textures.luma) != nil, CVMetalTextureGetTexture(textures.chroma) != nil,
                  CVPixelBufferGetWidth(stripe.pixelBuffer) >= s.layout.canvasWidth,
                  CVPixelBufferGetHeight(stripe.pixelBuffer) >= s.layout.placement(stripe: i).rows else { return false }
            nextMapped[ObjectIdentifier(stripe.pixelBuffer)] = textures
        }
        guard let cb = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(pipeline)
        var params = color
        enc.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)

        let L = s.layout
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let vp = viewportPixels.isEmpty ? CGRect(x: 0, y: 0, width: dw, height: dh) : viewportPixels
        let transform = transform(for: s)
        let scale = transform.backingScale * displayScale
        let ox = transform.desktopRect.minX * displayScale
        let oy = transform.desktopRect.minY * displayScale
        let clip = vp.intersection(CGRect(x: 0, y: 0, width: dw, height: dh))
        enc.setScissorRect(MTLScissorRect(x: Int(clip.minX), y: Int(clip.minY), width: Int(clip.width), height: Int(clip.height)))

        var keep: [AnyObject] = []
        for (i, stripe) in s.stripes.enumerated() {
            guard let stripe, let tex = nextMapped[ObjectIdentifier(stripe.pixelBuffer)],
                  let lumaTex = CVMetalTextureGetTexture(tex.luma),
                  let chromaTex = CVMetalTextureGetTexture(tex.chroma) else { continue }
            keep += [stripe.pixelBuffer, tex.luma, tex.chroma]
            var p = L.placement(stripe: i)
            let bufferH = lumaTex.height, bufferW = lumaTex.width
            if bufferH == L.visibleHeight && L.pictureHeight != L.visibleHeight { p.srcTop = 0 }  // VT already cropped
            guard p.rows > 0, p.srcTop + p.rows <= bufferH else { continue }
            let w = min(L.canvasWidth, bufferW)
            let x0 = ox, x1 = ox + Double(w) * scale
            let y0 = oy + Double(p.dstY) * scale, y1 = oy + Double(p.dstY + p.rows) * scale
            var quad = StripeQuad(
                dst: SIMD4(Float(x0 / dw * 2 - 1), Float(1 - y0 / dh * 2), Float(x1 / dw * 2 - 1), Float(1 - y1 / dh * 2)),
                src: SIMD4(0, Float(Double(p.srcTop) / Double(bufferH)),
                           Float(Double(w) / Double(bufferW)), Float(Double(p.srcTop + p.rows) / Double(bufferH))))
            enc.setVertexBytes(&quad, length: MemoryLayout<StripeQuad>.stride, index: 0)
            enc.setFragmentTexture(lumaTex, index: 0)
            enc.setFragmentTexture(chromaTex, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if cursorVisible, let point = cursorPoint, let image = cursorImage, let texture = cursorTexture {
            let anchor = transform.viewPoint(fromDesktop: point)
            // Sprite/hotspot are backing pixels, exactly like the video planes.
            let x = anchor.x * displayScale - image.hotspot.x * scale
            let y = anchor.y * displayScale - image.hotspot.y * scale
            var quad = StripeQuad(dst: SIMD4(Float(x / dw * 2 - 1), Float(1 - y / dh * 2),
                Float((x + CGFloat(image.width) * scale) / dw * 2 - 1),
                Float(1 - (y + CGFloat(image.height) * scale) / dh * 2)), src: SIMD4(0, 0, 1, 1))
            enc.setRenderPipelineState(cursorPipeline)
            enc.setVertexBytes(&quad, length: MemoryLayout<StripeQuad>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            keep.append(texture)
        }
        enc.endEncoding()
        mapped = nextMapped

        let retainer = GPURetainer(keep)
        let stats = self.stats
        stats.inFlight.add(1, ordering: .releasing)
        cb.addCompletedHandler { _ in
            withExtendedLifetime(retainer) {}
            stats.inFlight.subtract(1, ordering: .releasing)
        }
        if isNew {
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            var timing = s.timing
            timing.draw = DispatchTime.now().uptimeNanoseconds
            timing.target = UInt64(max(0, target) * 1e9)
            timing.probe = probeLuma(s)
            #endif
            let id = RenderStats.UpdateID(generation: s.generation, rtpTimestamp: s.rtpTimestamp)
            let mailbox = self.mailbox, onPresented = self.onPresented
            let onVideoPresented = self.onVideoPresented
            let geometry = s.layout.desktopGeometry, offerID = s.layout.offerID
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            let record = timing
            #endif
            Self.whenPresented(drawable) { t in
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                var timing = record
                #else
                let timing = s.timing
                #endif
                guard mailbox.isCurrent(s) else {
                    mailbox.note(timing, .obsolete)
                    stats.update { $0.obsoleteSnapshotsDropped += 1 }
                    return
                }
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                timing.presented = t > 0 ? UInt64(t * 1e9) : 0
                #endif
                var outcome = UpdateRecord.Outcome.presented
                var firstInGeneration = false
                stats.update { v in
                    guard t > 0 else { v.presentationsWithoutTime += 1; outcome = .noPresentedTime; return }
                    guard v.lastPresented != id else { v.repeatedUpdatePresentations += 1; outcome = .repeated; return }
                    firstInGeneration = v.lastPresented?.generation != id.generation
                    v.lastPresented = id
                    v.newDesktopsPresented += 1
                    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                    if v.fresh.presentedTimes.count < RenderStats.maxFresh {
                        v.fresh.presentedTimes.append(t)
                        v.fresh.submitToPresentMs.append((t * 1e9 - Double(timing.lastSubmit)) / 1e6)
                        if timing.arrival > 0 { v.fresh.arrivalToPresentMs.append((t * 1e9 - Double(timing.arrival)) / 1e6) }
                    }
                    #endif
                }
                mailbox.note(timing, outcome)
                if outcome == .presented { onVideoPresented?(offerID, id.generation, id.rtpTimestamp, UInt64(t * 1e9)) }
                if t > 0, firstInGeneration {
                    onPresented?(DesktopPresentation(generation: id.generation, offerID: offerID, geometry: geometry,
                                                      nanos: UInt64(t * 1e9)))
                }
            }
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        if let pending = cursorPending {             // every drawn cursor movement is sampled
            cursorPending = nil
            let drawn = DispatchTime.now().uptimeNanoseconds
            Self.whenPresented(drawable) { t in
                stats.update { v in
                    if t <= 0 { v.cursorDrawsWithoutTime += 1 } else if v.fresh.cursor.count < RenderStats.maxFresh {
                        v.fresh.cursor.append(CursorSample(event: pending.event, handled: pending.handled, draw: drawn,
                                                           presented: t, moves: pending.moves, late: true))
                    }
                }
            }
        }
        #endif
        cb.present(drawable)
        cb.commit()
        return true
    }

    /// Actual presentation time of `drawable` (0 when the system reports none).
    /// The simulator SDK has no drawable presentation callbacks: nothing is
    /// reported there, so a simulator run can never yield presentation evidence.
    private static func whenPresented(_ drawable: any CAMetalDrawable,
                                      _ body: @escaping @Sendable (CFTimeInterval) -> Void) {
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { body($0.presentedTime) }
        #endif
    }

    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    /// Luma of the scripted probe pixel in this desktop (-1 without a probe).
    private func probeLuma(_ s: DesktopSnapshot) -> Int {
        guard let p = probePoint else { return -1 }
        let L = s.layout
        for i in 0..<L.stripeCount {
            var place = L.placement(stripe: i)
            guard p.y >= place.dstY, p.y < place.dstY + place.rows, let pb = s.stripes[i]?.pixelBuffer else { continue }
            if CVPixelBufferGetHeight(pb) == L.visibleHeight && L.pictureHeight != L.visibleHeight { place.srcTop = 0 }
            let row = place.srcTop + p.y - place.dstY
            guard p.x >= 0, p.x < CVPixelBufferGetWidthOfPlane(pb, 0), row < CVPixelBufferGetHeightOfPlane(pb, 0),
                  CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return -1 }
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return -1 }
            return Int(base.load(fromByteOffset: row * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + p.x, as: UInt8.self))
        }
        return -1
    }
    #endif

    private func textures(for pb: CVPixelBuffer) -> (luma: CVMetalTexture, chroma: CVMetalTexture)? {
        if let t = mapped[ObjectIdentifier(pb)] { return t }
        var luma: CVMetalTexture?, chroma: CVMetalTexture?
        let s0 = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &luma)
        let s1 = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &chroma)
        guard s0 == kCVReturnSuccess, s1 == kCVReturnSuccess, let luma, let chroma else {
            evidence.set("texture.mapFailure", "plane0=\(s0) plane1=\(s1)")
            return nil
        }
        return (luma, chroma)
    }

    /// Records the actual decoder output contract once per generation.
    private func describe(_ pb: CVPixelBuffer, layout: StripeLayout, generation: UInt64) {
        describedGeneration = generation
        let format = CVPixelBufferGetPixelFormatType(pb)
        let planes = CVPixelBufferGetPlaneCount(pb)
        var planeText: [String] = []
        for p in 0..<planes {
            planeText.append("\(CVPixelBufferGetWidthOfPlane(pb, p))x\(CVPixelBufferGetHeightOfPlane(pb, p))"
                + "/stride \(CVPixelBufferGetBytesPerRowOfPlane(pb, p))")
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        func attachment(_ key: CFString) -> String {
            CVBufferCopyAttachment(pb, key, nil).map { "\($0)" } ?? "absent"
        }
        #endif
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let fullRange = format == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let is444 = planes == 2 && CVPixelBufferGetWidthOfPlane(pb, 1) == w && CVPixelBufferGetHeightOfPlane(pb, 1) == h
        unsupportedFormat = !(is444 && (fullRange || format == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange))
        color = ColorParams.make(matrix: matrix, fullRange: fullRange)
        if let attachments = CVBufferCopyAttachments(pb, .shouldPropagate),
           let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            layer.colorspace = space
            evidence.set("output.layerColorSpace", "\(space.name.map { String($0) } ?? "\(space)")")
        }
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let facts: [(String, String)] = [
            ("output.pixelFormat", fourCC(format)),
            ("output.size", "\(w)x\(h)"),
            ("output.planes", planeText.joined(separator: "; ")),
            ("output.chroma444FullResolution", String(is444)),
            ("output.ioSurfaceBacked", String(CVPixelBufferGetIOSurface(pb) != nil)),
            ("output.matrix", attachment(kCVImageBufferYCbCrMatrixKey)),
            ("output.primaries", attachment(kCVImageBufferColorPrimariesKey)),
            ("output.transfer", attachment(kCVImageBufferTransferFunctionKey)),
            ("output.cleanAperture", attachment(kCVImageBufferCleanApertureKey)),
            ("output.chromaLocation", attachment(kCVImageBufferChromaLocationTopFieldKey)),
            ("output.metalMapping", "plane0 r8Unorm, plane1 rg8Unorm via CVMetalTextureCache (no CPU copy)"),
            ("output.supportedForPresentation", String(!unsupportedFormat)),
            ("layout", layout.summary),
        ]
        for (k, v) in facts { evidence.set(k, v) }
        #endif
        print("[vicinia] output \(fourCC(format)) \(w)x\(h) planes=\(planeText) 444=\(is444) matrix=\(matrix ?? "absent") layout: \(layout.summary)")
    }
}

enum RendererError: Error {
    case metalUnavailable
    case textureCache
}
