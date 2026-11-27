// Vicinia tests — build-specific session instrumentation.
// SPDX-License-Identifier: MIT

import CoreMedia
import Foundation
import Testing
import UIKit
import VideoToolbox
@testable import Vicinia

@Suite("Session instrumentation", .serialized)
@MainActor
struct InstrumentationTests {
    @Test(.appLifecycleExclusive) func displayActivityContinuesAfterLifecycleRecordingLimit() {
        let controller = SessionController(slot: LiveSessionSlot()) // parallel suites: not the app's single-session owner
        controller.start(SessionSource(id: "lifecycle", clipURL: nil,
                                       live: LiveRequest(host: "lifecycle-test.invalid", username: "test",
                                                         password: SecretBytes("unused"))), window: nil)
        defer { controller.stop() }
        let notifications = NotificationCenter.default
        for _ in 0..<64 {
            notifications.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(!controller.mailbox.presentationProgress.displayActive)
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(controller.mailbox.presentationProgress.displayActive)
    }
    @Test func liveStartupAndEvidenceMatchBuild() async throws {
        let host = "evidence-test-\(UUID()).invalid"
        let prefix = "evidence-live-\(host)-"
        let fm = FileManager.default
        let docs = URL.documentsDirectory
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        func evidenceFiles() throws -> [URL] {
            try fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        }

        let controller = SessionController(slot: LiveSessionSlot()) // parallel suites: not the app's single-session owner
        #expect(controller.terminalTitle == nil)
        #expect(controller.connectionProgress == "Preparing the session…")
        #expect(try evidenceFiles().isEmpty)
        controller.start(SessionSource(id: host, clipURL: nil,
                                       live: LiveRequest(host: host, username: "test",
                                                         password: SecretBytes("unused"))), window: nil)
        defer {
            controller.stop()
            if let files = try? evidenceFiles() {
                for file in files { try? fm.removeItem(at: file) }
            }
        }
        #expect(controller.terminalTitle == nil)
        #expect(controller.connectionProgress == "Connecting to the Mac…")

        // Drive a completed update into the session's real mailbox. The timer
        // and stop() are the same writers used by an ordinary live session.
        var record = UpdateRecord()
        record.rtpTimestamp = 42
        controller.mailbox.note(record, .presented)
        #expect(controller.mailbox.presentationProgress.last > 0)

        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        #expect(EvidenceLog.measurementEnabled)
        let output = try #require(controller.evidence?.output)
        let deadline = ContinuousClock.now + .seconds(2)
        while !fm.fileExists(atPath: output.fileURL.path()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.hud.first?.hasPrefix("Vicinia — ") == true)
        #expect(fm.fileExists(atPath: output.fileURL.path()))
        controller.stop()
        output.queue.sync {}
        let facts = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.fileURL)) as? [String: String])
        #expect(facts["trace.file"] == output.traceURL.lastPathComponent)
        #expect(facts["evidence.started"] != nil)
        #expect(facts["evidence.written"] != nil)
        #expect(facts["memory.footprintMB"] != nil)
        #if DEBUG
        #expect(facts["build.configuration"] == "Debug")
        #else
        #expect(facts["build.configuration"] == "Release")
        #endif
        let lines = try String(contentsOf: output.traceURL, encoding: .utf8).split(separator: "\n")
        record.outcome = .presented
        #expect(lines.map(String.init) == [UpdateRecord.csvHeader, record.csv])
        #else
        #expect(!EvidenceLog.measurementEnabled)
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(try evidenceFiles().isEmpty)
        controller.stop()
        #expect(try evidenceFiles().isEmpty)
        #expect(controller.mailbox.drainRecords().isEmpty)
        #expect(controller.mailbox.counters.recordsDropped == 0)
        #expect(controller.evidence?.value("memory.footprintMB") == nil)
        #endif
    }

    @Test func persistedMediaFaultOnlyDropsDatagramsInInstrumentedBuilds() throws {
        let domain = "Vicinia.Instrumentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain(["drop-media": "0,30", "host": "my-mac.local", "user": "alice"], forName: domain)

        let evidence = EvidenceLog()
        let pipeline = MediaPipeline(ssrcToStripe: [:], canvas: nil, ruleOverride: nil,
                                     mailbox: DesktopUpdateMailbox(), evidence: evidence)
        let transport = MediaTransport(pipeline: pipeline, evidence: evidence, tiles: 4)
        pipeline.queue.sync {
            transport.startFeedback(defaults: defaults)
            defer { transport.stop() }
            transport.ingestVideo(Data([0x80, 100]))
            #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
            #expect(transport.counters.droppedByFaultInjection == 1)
            #expect(transport.counters.videoDatagrams == 0)
            #expect(evidence.value("fault.dropMedia") != nil)
            #else
            #expect(transport.counters.droppedByFaultInjection == 0)
            #expect(transport.counters.videoDatagrams == 1)
            #expect(evidence.value("fault.dropMedia") == nil)
            #endif
        }
        #expect(defaults.string(forKey: "host") == "my-mac.local")
        #expect(defaults.string(forKey: "user") == "alice")
    }

    /// The real pipeline and VideoToolbox decoder: one encoded HEVC picture
    /// becomes a committed desktop in every build; only instrumented builds
    /// capture its sequence, arrival, submission and decode times. The app
    /// requires hardware decoding, which simulators do not provide.
    @Test(.enabled(if: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), "needs a hardware HEVC decoder (physical device)"))
    func realDecoderTimingIsCapturedOnlyInInstrumentedBuilds() async throws {
        let nals = try Self.encodedHEVCPicture(width: 256, height: 128)
        let ssrc: UInt32 = 0x5EED, ts: UInt32 = 9_000
        // Records are requested in every build, so they show what the decoder captured.
        let mailbox = DesktopUpdateMailbox(recordsUpdates: true)
        let pipeline = MediaPipeline(ssrcToStripe: [ssrc: 0], canvas: nil, ruleOverride: nil,
                                     mailbox: mailbox, evidence: EvidenceLog())
        defer { pipeline.queue.sync { pipeline.resetStream() } }
        let packet = Self.aggregationPacket(ssrc: ssrc, timestamp: ts, nals: nals)
        let arrival = DispatchTime.now().uptimeNanoseconds
        pipeline.queue.sync { pipeline.ingest(packet, arrival: arrival) }
        let deadline = ContinuousClock.now + .seconds(2)
        var taken = mailbox.take()
        while taken == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            taken = mailbox.take()
        }
        let c = pipeline.counters.snapshot
        let desktop = try #require(taken, "no desktop: submitted \(c.decodeSubmitted) decoded \(c.decoded) failed \(c.decodeFailed)")
        let stripe = try #require(desktop.stripes.first ?? nil)
        #expect(desktop.rtpTimestamp == ts && stripe.rtpTimestamp == ts && stripe.stripe == 0)
        #expect(CVPixelBufferGetWidth(stripe.pixelBuffer) == 256)
        #expect(desktop.timing.commit >= arrival)            // the pacing input, in every build
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        #expect(stripe.auSequence == 1)
        #expect(stripe.arrivalNanos == arrival)
        #expect(stripe.submitNanos >= arrival && stripe.decodedNanos >= stripe.submitNanos)
        #expect(desktop.timing.commit >= stripe.decodedNanos)
        #expect(desktop.timing.arrival == arrival)
        #expect(desktop.timing.firstSubmit == stripe.submitNanos && desktop.timing.lastSubmit == stripe.submitNanos)
        #expect(desktop.timing.lastDecoded == stripe.decodedNanos)
        #else
        #expect(stripe.auSequence == 0 && stripe.arrivalNanos == 0)
        #expect(stripe.submitNanos == 0 && stripe.decodedNanos == 0)
        #expect(desktop.timing.arrival == 0 && desktop.timing.lastSubmit == 0 && desktop.timing.lastDecoded == 0)
        #endif
    }

    /// One HEVC picture from the platform encoder: its parameter sets, then its NAL units.
    nonisolated private static func encodedHEVCPicture(width: Int, height: Int) throws -> [Data] {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        let session = try #require(created, "no HEVC encoder: \(status)")
        defer { VTCompressionSessionInvalidate(session) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let image = try #require(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(image) {
            memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), 0x80,
                   CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let output = Recorder<[Data]>()
        let encoded = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: .zero, duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else { return }
            let nals = Self.nalUnits(of: sample)
            output.add(nals)
        }
        try #require(encoded == noErr, "encode status \(encoded)")
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try #require(output.all.first, "the encoder produced no picture")
    }

    /// Parameter sets from the format description, then the length-prefixed NAL units.
    nonisolated private static func nalUnits(of sample: CMSampleBuffer) -> [Data] {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var nals: [Data] = []
        var count = 0
        var headerLength: Int32 = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &headerLength)
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            if let pointer { nals.append(Data(bytes: pointer, count: size)) }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        let n = Int(headerLength)
        var offset = 0
        while n > 0, offset + n <= bytes.count {
            let size = bytes[offset ..< offset + n].reduce(0) { $0 << 8 | Int($1) }
            offset += n
            guard size > 0, offset + size <= bytes.count else { break }
            nals.append(Data(bytes[offset ..< offset + size]))
            offset += size
        }
        return nals
    }

    /// One marked RTP packet (payload type 100): an Apple aggregation packet,
    /// i.e. header and DONL, then every NAL unit with its 16-bit size.
    nonisolated private static func aggregationPacket(ssrc: UInt32, timestamp: UInt32, nals: [Data]) -> Data {
        var w = ByteWriter()
        w.u8(0x80); w.u8(0x80 | 100); w.u16(1); w.u32(timestamp); w.u32(ssrc)
        w.u8(48 << 1); w.u8(1); w.u16(0)
        for nal in nals { w.u16(UInt16(nal.count)); w.append(nal) }
        return Data(w.bytes)
    }
}
