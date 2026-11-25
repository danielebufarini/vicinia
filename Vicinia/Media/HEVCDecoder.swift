// Vicinia — VideoToolbox HEVC decoder (one shared session/DPB for all stripes).
// SPDX-License-Identifier: MIT
//
// One VTDecompressionSession for every stripe (cross-stripe references),
// parameter sets via CMVideoFormatDescription rather than in-band, '444f'
// bi-planar full-range output; mandatory hardware decoder, asynchronous
// output, one sample per complete AU, no CPU plane copy.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A decoded stripe picture handed from VideoToolbox to the renderer.
/// Ownership invariant (why @unchecked Sendable is sound): the pixel buffer is
/// a finished decoder output that nobody writes after the hand-off; consumers
/// only read it through IOSurface-backed Metal textures, and every holder keeps
/// a strong reference until its GPU work has completed.
struct DecodedStripe: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let stripe: Int
    let rtpTimestamp: UInt32
    let generation: UInt64
    let auSequence: UInt64
    let submitNanos: UInt64
    let decodedNanos: UInt64
    /// First packet arrival of this picture (0 = unknown).
    var arrivalNanos: UInt64 = 0
}

enum DecoderEvent: Sendable {
    case decoded(DecodedStripe)
    case failed(stripe: Int, rtpTimestamp: UInt32, generation: UInt64, status: OSStatus)
}

struct DecoderFacts: Sendable {
    var requiredHardware = false
    var usingHardware: Bool?           // kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder
    var requestedPixelFormat: String
    var createStatus: OSStatus
}

enum DecoderError: Error {
    case formatDescription(OSStatus)
    case session(OSStatus)
}

func fourCC(_ v: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: bytes, as: UTF8.self) : String(v)
}

/// Not thread-safe: owned by the serial media context. Output arrives on a
/// VideoToolbox thread and goes straight to `sink` (no wait for the renderer).
final class HEVCDecoder {
    let generation: UInt64
    let formatDescription: CMVideoFormatDescription
    private(set) var facts: DecoderFacts
    private let session: VTDecompressionSession
    private let sink: @Sendable (DecoderEvent) -> Void
    #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
    private var auSequence: UInt64 = 0
    #endif

    /// `pixelFormat` nil lets VideoToolbox choose its native output format.
    init(parameterSets: [Data], generation: UInt64, pixelFormat: OSType?,
         sink: @escaping @Sendable (DecoderEvent) -> Void) throws {
        self.generation = generation
        self.sink = sink
        formatDescription = try Self.makeFormatDescription(parameterSets)

        // Mandatory hardware decode: creation fails rather than silently
        // falling back to software.
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        if let pixelFormat { attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat }
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatDescription,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw DecoderError.session(status) }
        session = created
        facts = DecoderFacts(requiredHardware: true,
                             requestedPixelFormat: pixelFormat.map(fourCC) ?? "native",
                             createStatus: status)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var value: CFTypeRef?
        let q = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: $0)
        }
        if q == noErr, let number = value as? NSNumber { facts.usingHardware = number.boolValue }
    }

    deinit { invalidate() }

    func invalidate() {
        VTDecompressionSessionInvalidate(session)
    }

    /// Submits the VCL NAL units of one complete AU as one length-prefixed sample.
    /// `now` (the submission time) is read only by instrumented builds.
    func decode(_ au: AccessUnit, vclNALs: [Data], now: @autoclosure () -> UInt64) {
        // Sequence, times and arrival feed only the measurement trace: zero in standard builds.
        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        let submitted = now()
        #else
        let submitted: UInt64 = 0
        #endif
        let total = vclNALs.reduce(0) { $0 + 4 + $1.count }
        guard total > 0 else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(total)
        for nal in vclNALs {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block else { return report(au, kCMBlockBufferBadCustomBlockSourceErr) }
        let copied = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: total)
        }
        guard copied == noErr else { return report(au, copied) }
        var sample: CMSampleBuffer?
        var size = total
        let made = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard made == noErr, let sample else { return report(au, made) }

        #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
        auSequence += 1
        let seq = auSequence, arrival = au.firstArrivalNanos
        #else
        let seq: UInt64 = 0, arrival: UInt64 = 0
        #endif
        let stripe = au.stripe, ts = au.rtpTimestamp, gen = generation
        let sink = self.sink
        let handler: @Sendable (OSStatus, VTDecodeInfoFlags, CVImageBuffer?, CMTime, CMTime) -> Void = {
            status, _, image, _, _ in
            if status == noErr, let image {
                #if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
                let decoded = DispatchTime.now().uptimeNanoseconds
                #else
                let decoded: UInt64 = 0
                #endif
                sink(.decoded(DecodedStripe(pixelBuffer: image, stripe: stripe, rtpTimestamp: ts,
                                            generation: gen, auSequence: seq, submitNanos: submitted,
                                            decodedNanos: decoded, arrivalNanos: arrival)))
            } else {
                sink(.failed(stripe: stripe, rtpTimestamp: ts, generation: gen, status: status))
            }
        }
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil, outputHandler: handler)
        if st != noErr { report(au, st) }
    }

    private func report(_ au: AccessUnit, _ status: OSStatus) {
        sink(.failed(stripe: au.stripe, rtpTimestamp: au.rtpTimestamp, generation: generation, status: status))
    }

    static func makeFormatDescription(_ sets: [Data]) throws -> CMVideoFormatDescription {
        let arrays = sets.map { [UInt8]($0) }
        let pointers = arrays.map { a -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: a.count)
            p.initialize(from: a, count: a.count)
            return p
        }
        defer { for (p, a) in zip(pointers, arrays) { p.deinitialize(count: a.count); p.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = arrays.map(\.count)
        var description: CMFormatDescription?
        let status = constPointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: arrays.count,
                    parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw DecoderError.formatDescription(status) }
        return description
    }
}
