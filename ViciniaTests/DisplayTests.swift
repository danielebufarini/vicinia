// Vicinia — focused geometry and offer-generation regression tests.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

@Suite("Dynamic display geometry")
struct DisplayTests {
    @Test func profilesShareBackingAndPortraitFitsProportionally() throws {
        let retina = DisplayRequest(viewportPixels: CGSize(width: 2329, height: 1201), profile: .retina)
        let space = DisplayRequest(viewportPixels: CGSize(width: 2329, height: 1201), profile: .moreSpace)
        #expect(retina.backingWidth == 2328 && retina.backingHeight == 1200)
        #expect(retina.logicalWidth == 1164 && space.logicalWidth == 2328)
        #expect(retina.backingWidth == space.backingWidth && retina.backingHeight == space.backingHeight)
        let portrait = DisplayRequest(viewportPixels: CGSize(width: 1260, height: 2430), profile: .retina)
        #expect(portrait.proportional && portrait.backingHeight == 2160)
        #expect(abs(Double(portrait.backingWidth) / 2160 - 1260.0 / 2430) < 0.002)
        // Complete dynamic descriptor, first mode, remote 2x (never UIKit 3x).
        let di = Array(retina.message.dropFirst(12))
        var flags = ByteReader(di, offset: 0x7A)
        #expect(try flags.u32() == 1 && flags.u32() == 4)
        var reserved = ByteReader(di, offset: 0x96)
        #expect(try reserved.u32() == 7 && reserved.u16() == 5)
        var mode = ByteReader(di, offset: 0x9C)
        #expect(try mode.u32() == 2328 && mode.u32() == 1200 && mode.u32() == 1164 && mode.u32() == 600)
        #expect(try mode.u64() == Double(60).bitPattern)
        #expect(RFB.rearmUpdates(width: 1164, height: 600).count == 26)
    }

    @Test func authoritativeLayoutKeepsOriginsAndRejectsTruncatedEntries() throws {
        var b = [UInt8](repeating: 0, count: 76)
        b.putU16(5, at: 0); b.putU16(1164, at: 2); b.putU16(600, at: 4)
        b.putU16(2328, at: 6); b.putU16(1200, at: 8); b.putU16(1, at: 18)
        // y0,x0,y1,x1 in point and backing rects.
        for (i, v) in [20, 10, 620, 1174, 40, 20, 1240, 2348].enumerated() { b.putU16(UInt16(v), at: 40 + i * 2) }
        let g = try #require(DisplayLayout(b)?.geometry)
        #expect(g.logical == CGRect(x: 10, y: 20, width: 1164, height: 600))
        #expect(g.backing == CGRect(x: 20, y: 40, width: 2328, height: 1200))
        #expect(DisplayLayout(Array(b.dropLast())) == nil)
    }

    @Test func sharedTransformHandlesLetterboxOriginZoomAndClampedPan() throws {
        let g = DesktopGeometry(logical: CGRect(x: 10, y: 20, width: 600, height: 1000),
                                backing: CGRect(x: 20, y: 40, width: 1200, height: 2000))
        let vp = CGRect(x: 68, y: 0, width: 776, height: 400)
        let fit = ViewportTransform(geometry: g, viewport: vp)
        #expect(fit.desktopPoint(fromView: CGPoint(x: 70, y: 10)) == nil)  // letterbox
        #expect(fit.desktopPoint(fromView: CGPoint(x: 0, y: 0)) == nil)    // unsafe area
        for zoom in [1.0, 2, 4] {
            let t = ViewportTransform(geometry: g, viewport: vp, zoom: zoom, pan: CGPoint(x: 99_999, y: -99_999))
            let center = CGPoint(x: vp.midX, y: vp.midY)
            let p = try #require(t.desktopPoint(fromView: center))
            let inverse = t.viewPoint(fromDesktop: p)
            #expect(abs(inverse.x - center.x) < 0.00001 && abs(inverse.y - center.y) < 0.00001)
            #expect(t.desktopRect.minY <= vp.minY && t.desktopRect.maxY >= vp.maxY)
        }
    }

    /// Physical host evidence: Retina wire (756,378) arrived at
    /// global logical (378,189), i.e. Safari client (378,107) below its 82pt
    /// chrome. The host consumes BACKING pixels, not logical coordinates.
    @Test func wireCoordinatesUseHostBackingUnits() {
        let retina = DesktopGeometry(logical: CGRect(x: 10, y: 20, width: 1164, height: 600),
                                     backing: CGRect(x: 20, y: 40, width: 2328, height: 1200))
        let center = retina.wirePoint(fromDesktop: CGPoint(x: 592, y: 320))
        #expect(center.x == 1184 && center.y == 640)
        let tl = retina.wirePoint(fromDesktop: CGPoint(x: 10, y: 20))
        #expect(tl.x == 20 && tl.y == 40)
        let br = retina.wirePoint(fromDesktop: CGPoint(x: 1174, y: 620))
        #expect(br.x == 2347 && br.y == 1239)
        let space = DesktopGeometry(logical: CGRect(x: 20, y: 40, width: 2328, height: 1200),
                                    backing: CGRect(x: 20, y: 40, width: 2328, height: 1200))
        let p = space.wirePoint(fromDesktop: CGPoint(x: 1184, y: 640))
        #expect(p.x == 1184 && p.y == 640)       // no second HiDPI multiplication
    }
}

@Suite("Fresh media offers", .serialized)
struct MediaGenerationTests {
    @Test func reofferRejectsOldProtectionAndResolvesNewSSRCs() throws {
        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        let old = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        let fresh = try MediaOffer.make(clientName: "test", hardwareModel: "test", osBuild: "test")
        #expect(old.keys.videoFromHost != fresh.keys.videoFromHost)
        try pipeline.queue.sync {
            defer { transport.stop(); pipeline.resetStream() }
            func packet(ssrc: UInt32) -> [UInt8] {
                var w = ByteWriter()
                w.u8(0x80); w.u8(100); w.u16(1); w.u32(90_000); w.u32(ssrc); w.append([2, 1, 0, 1, 0xAA])
                return w.bytes
            }
            try transport.configure(keys: old.keys, videoSSRC: old.videoSSRC, audioSSRC: old.audioSSRC, offerID: 1)
            let oldSender = try SRTPSession(keySalt: old.keys.videoFromHost, inbound: false)
            let oldPacket = try oldSender.protectRTP(packet(ssrc: 0x10))
            transport.ingestVideo(oldPacket)
            for ssrc: UInt32 in 0x11...0x13 { transport.ingestVideo(try oldSender.protectRTP(packet(ssrc: ssrc))) }
            #expect(evidence.value("media.ssrcGroup.offer1") != nil)
            try transport.configure(keys: fresh.keys, videoSSRC: fresh.videoSSRC, audioSSRC: fresh.audioSSRC, offerID: 2)
            transport.ingestVideo(oldPacket)
            #expect(transport.counters.srtpAuthFailures == 1)
            let newSender = try SRTPSession(keySalt: fresh.keys.videoFromHost, inbound: false)
            for ssrc: UInt32 in 0x40...0x42 { transport.ingestVideo(try newSender.protectRTP(packet(ssrc: ssrc))) }
            #expect(evidence.value("media.ssrcGroup.offer2") == nil)
            transport.ingestVideo(try newSender.protectRTP(packet(ssrc: 0x43)))
            #expect(evidence.value("media.ssrcGroup.offer2") == "0x00000040,0x00000041,0x00000042,0x00000043")
            #expect(pipeline.counters.snapshot.decodeSubmitted == 0)
        }
    }
}
