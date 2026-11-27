// Vicinia — HPSS audio stream: wire format, reorder and loss handling,
// playout pacing and AAC-ELD decoding. Value types and one queue-confined
// decoder; scheduling and the device output live in AudioPipeline.
// SPDX-License-Identifier: MIT
//
// Observed HPSS audio uses RTP payload type 101 and the offer's audio SRTP
// keys. Each packet carries one raw AAC-ELD access unit with SBR, without
// RFC 3640 AU headers: 48 kHz, stereo, 480 frames (10 ms) per unit.
// Silent packets can carry a four-byte access unit.

import AVFAudio
import Foundation

enum HPSSAudio {
    static let payloadType: UInt8 = 101
    static let sampleRate = 48_000.0
    static let channelCount: AVAudioChannelCount = 2
    static let framesPerPacket = 480
    static let packetNanos: UInt64 = 10_000_000
    /// ISO/IEC 14496-3 decoder input buffer: at most 6144 bits per channel per access unit.
    static let maxAccessUnitBytes = 6144 / 8 * 2
    /// The host's declared decoder configuration: an MPEG-4 ES descriptor
    /// around the AudioSpecificConfig f8e65132e000 (AAC-ELD, 48 kHz, two
    /// channels, 480-sample frames, single-rate SBR). AudioToolbox configures
    /// this decoder from the stream description; its output was identical
    /// with this cookie, another encoder's or none (macOS 27.2.1), so the
    /// stream description, notably 480 frames per access unit, is what decoding
    /// depends on.
    static let magicCookie: [UInt8] = [
        0x03, 0x80, 0x80, 0x80, 0x26, 0x00, 0x00, 0x00, 0x04, 0x80, 0x80, 0x80, 0x18, 0x40, 0x14, 0x00,
        0x18, 0x00, 0x00, 0x01, 0x38, 0x80, 0x00, 0x00, 0x00, 0x00, 0x05, 0x80, 0x80, 0x80, 0x06, 0xF8,
        0xE6, 0x51, 0x32, 0xE0, 0x00, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
    ]

    static func pcmFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false)
    }

    static func accessUnitFormat(cookie: [UInt8]) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD_SBR,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket),
                                               mBytesPerFrame: 0, mChannelsPerFrame: channelCount, mBitsPerChannel: 0,
                                               mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        format.magicCookie = Data(cookie)
        return format
    }
}

/// One audio RTP packet that already passed SRTP authentication and replay checks.
struct AudioPacket: Sendable {
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data
    let arrival: UInt64                 // monotonic nanoseconds
    let mediaGeneration: UInt64         // the media offer this packet belongs to
}

/// Restores sequence order within a bounded window and decides losses. A new
/// SSRC, a newer media offer or a forward jump of more than `maxJump` packets is a new
/// stream: nothing older is played after it.
struct AudioReorderBuffer {
    enum Restart: String, Sendable { case ssrc, mediaGeneration, sequenceJump }
    enum Event: Equatable {
        case play(Data, timestamp: UInt32, sequence: UInt64, arrival: UInt64)
        case lost(Int)
        case restart(Restart)
    }
    struct Counters: Equatable, Sendable {
        var received = 0, played = 0, duplicates = 0, late = 0, reordered = 0, lost = 0, restarts = 0
    }
    /// Packets held while an earlier one is missing (160 ms): longer than the
    /// largest playout target, so a packet held beyond it would be late anyway.
    static let capacity = 16
    /// 15 s at 100 packets/s, beyond the 1024-packet SRTP replay window.
    /// A smaller forward gap is packet loss. Backward packets never rebase it.
    static let maxJump: Int64 = 1500

    private(set) var counters = Counters()
    private var stream: (ssrc: UInt32, generation: UInt64)?
    private var next: UInt64 = 0
    private var highest: UInt64 = 0
    private var held: [UInt64: (payload: Data, timestamp: UInt32, arrival: UInt64)] = [:]

    var heldCount: Int { held.count }
    var source: (ssrc: UInt32, generation: UInt64)? { stream }

    mutating func reset() {
        stream = nil
        held = [:]
    }

    mutating func insert(_ p: AudioPacket, reorderWait: UInt64) -> [Event] {
        var out: [Event] = []
        counters.received += 1
        if let s = stream, p.mediaGeneration < s.generation {
            counters.late += 1
            return out
        }
        if let s = stream, s.ssrc != p.ssrc || s.generation != p.mediaGeneration {
            out.append(.restart(s.generation != p.mediaGeneration ? .mediaGeneration : .ssrc))
            counters.restarts += 1
            reset()
        }
        let ext: UInt64
        if stream == nil {
            stream = (p.ssrc, p.mediaGeneration)
            ext = 1 << 32 | UInt64(p.sequence)          // headroom: backward deltas never go below zero
            next = ext; highest = ext
        } else {
            let delta = Int64(Int16(bitPattern: p.sequence &- UInt16(truncatingIfNeeded: highest)))
            if delta > Self.maxJump {
                out.append(.restart(.sequenceJump))
                counters.restarts += 1
                held = [:]
                ext = highest &+ UInt64(bitPattern: delta)
                next = ext; highest = ext
            } else {
                ext = UInt64(Int64(highest) + delta)
            }
        }
        if ext < next { counters.late += 1; return out }              // already played or given up
        if held[ext] != nil { counters.duplicates += 1; return out }
        if ext < highest { counters.reordered += 1 } else { highest = ext }
        held[ext] = (p.payload, p.timestamp, p.arrival)
        out += release()
        if held.count > Self.capacity { out += giveUpGap() }
        out += expire(now: p.arrival, reorderWait: reorderWait)
        return out
    }

    /// A missing packet is lost once a later one has waited `reorderWait`.
    mutating func expire(now: UInt64, reorderWait: UInt64) -> [Event] {
        guard held[next] == nil, let first = held.keys.min(), let waiting = held[first],
              now >= waiting.arrival, now - waiting.arrival >= reorderWait else { return [] }
        return giveUpGap()
    }

    private mutating func giveUpGap() -> [Event] {
        guard let first = held.keys.min(), first > next else { return release() }
        let missing = Int(first - next)
        counters.lost += missing
        next = first
        return [.lost(missing)] + release()
    }

    private mutating func release() -> [Event] {
        var out: [Event] = []
        while let h = held.removeValue(forKey: next) {
            out.append(.play(h.payload, timestamp: h.timestamp, sequence: next, arrival: h.arrival))
            counters.played += 1
            next += 1
        }
        return out
    }
}

/// Paces scheduled audio: a playout target derived from measured arrival
/// jitter and the route's I/O buffer, and a level kept near it by resampling
/// a block by a few frames (drift and jitter changes) or, far above it,
/// dropping one (bursts). Nothing accumulates to compensate drift.
struct PlayoutControl {
    enum Decision: Equatable { case prime, play(adjust: Int), drop }
    struct Counters: Equatable, Sendable { var primes = 0, shortened = 0, lengthened = 0, dropped = 0, correlated = 0 }

    /// Upper bound on the jitter delay: audio that trails video by more than
    /// about 125 ms is perceptible (ITU-R BT.1359); output latency adds to it.
    static let maximumTargetFrames = 4800
    /// Frames removed or added by one correction (0.8 % of a block).
    static let correctionFrames = 4
    static let hysteresisFrames = 240

    private(set) var targetFrames = 1440
    private(set) var minimumFrames = 1440
    private(set) var counters = Counters()
    /// RFC 3550 interarrival jitter, from arrival times against the 10 ms packet clock.
    private(set) var jitterNanos = 0.0
    private var lastArrival: (sequence: UInt64, arrival: UInt64)?
    private var smoothedLevel: Double?

    /// One packet plus two render quanta of the current route.
    mutating func setRoute(ioBufferDuration: TimeInterval) {
        let quantum = Int((max(0, ioBufferDuration) * HPSSAudio.sampleRate).rounded(.up))
        minimumFrames = min(Self.maximumTargetFrames, max(2 * HPSSAudio.framesPerPacket, HPSSAudio.framesPerPacket + 2 * quantum))
        updateTarget()
    }

    mutating func restartStream() {
        lastArrival = nil
        jitterNanos = 0
        smoothedLevel = nil
        updateTarget()
    }

    mutating func noteArrival(sequence: UInt64, arrival: UInt64) {
        defer { lastArrival = (sequence, arrival) }
        guard let last = lastArrival else { return }
        let expected = (Double(sequence) - Double(last.sequence)) * Double(HPSSAudio.packetNanos)
        let d = abs((Double(arrival) - Double(last.arrival)) - expected)
        guard d < 1e9 else { return }                   // a pause or a new stream, not jitter
        jitterNanos += (d - jitterNanos) / 16
        updateTarget()
    }

    private mutating func updateTarget() {
        let jitterFrames = Int(3 * jitterNanos * HPSSAudio.sampleRate / 1e9)
        targetFrames = min(Self.maximumTargetFrames, minimumFrames + jitterFrames)
    }

    /// `level`: frames scheduled ahead of the player when this block is due.
    mutating func decide(level: Int, avErrorFrames: Double? = nil) -> Decision {
        if avErrorFrames != nil { counters.correlated += 1 }
        guard level > 0 else {
            counters.primes += 1
            smoothedLevel = Double(targetFrames)
            return .prime
        }
        let smoothed = (smoothedLevel ?? Double(level)) + (Double(level) - (smoothedLevel ?? Double(level))) / 16
        smoothedLevel = smoothed
        let error = avErrorFrames ?? 0
        let desired = min(Double(Self.maximumTargetFrames), max(Double(minimumFrames), Double(targetFrames) - error))
        let occupancyDeadband = Double(Self.hysteresisFrames)
        // Sender-clock errors have already been filtered. A 2.5 ms deadband
        // tracks slow drift without changing the occupancy-only behavior.
        let deadband = avErrorFrames == nil ? occupancyDeadband : occupancyDeadband / 2
        if Double(level) > desired + 4 * occupancyDeadband + Double(HPSSAudio.framesPerPacket) {
            counters.dropped += 1
            return .drop
        }
        // At the floor an A/V correction can shorten one block as long as
        // the live buffer still has the route margin. Occupancy takes over
        // below it, and authoritative timing never moves the target lower.
        if (avErrorFrames == nil || level >= minimumFrames),
           smoothed > desired + deadband || (error > deadband && smoothed >= desired) {
            counters.shortened += 1
            return .play(adjust: -Self.correctionFrames)
        }
        if smoothed < desired - deadband {
            counters.lengthened += 1
            return .play(adjust: Self.correctionFrames)
        }
        return .play(adjust: 0)
    }
}

enum BlockResampler {
    /// Linear resampling of a short block to `count` frames, keeping both end
    /// samples so neighbouring blocks stay continuous.
    static func resample(_ input: AVAudioPCMBuffer, to count: Int) -> AVAudioPCMBuffer? {
        let n = Int(input.frameLength)
        guard n > 1, count > 1, let src = input.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(count)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        let step = Double(n - 1) / Double(count - 1)
        for channel in 0..<Int(input.format.channelCount) {
            let s = src[channel], d = dst[channel]
            for i in 0..<count {
                let position = Double(i) * step
                let j = min(Int(position), n - 2)
                let f = Float(position - Double(j))
                d[i] = s[j] + (s[j + 1] - s[j]) * f
            }
        }
        return out
    }
}

/// AudioToolbox AAC-ELD decoder for the host's configuration. Not
/// thread-safe: owned by the audio queue.
final class AACELDDecoder {
    enum Failure: Error, Equatable { case unsupported, invalidAccessUnit(Int), decode(Int) }

    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let input: AVAudioCompressedBuffer

    init(cookie: [UInt8] = HPSSAudio.magicCookie) throws {
        guard let compressed = HPSSAudio.accessUnitFormat(cookie: cookie), let pcm = HPSSAudio.pcmFormat(),
              let converter = AVAudioConverter(from: compressed, to: pcm) else { throw Failure.unsupported }
        outputFormat = pcm
        self.converter = converter
        input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: HPSSAudio.maxAccessUnitBytes)
        // Creating the converter validates nothing: decode the host's silence
        // access unit to prove this device can decode the format.
        guard (try? decode(Data([0, 0, 0, 0]))) != nil else { throw Failure.unsupported }
        converter.reset()
    }

    /// Decodes one access unit into a new buffer. An access unit that yields
    /// no frames was not decodable: every one carries 480 frames.
    func decode(_ accessUnit: Data) throws -> AVAudioPCMBuffer {
        guard (1...HPSSAudio.maxAccessUnitBytes).contains(accessUnit.count) else {
            throw Failure.invalidAccessUnit(accessUnit.count)
        }
        accessUnit.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: accessUnit.count) }
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                     mDataByteSize: UInt32(accessUnit.count))
        input.packetCount = 1
        input.byteLength = UInt32(accessUnit.count)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(2 * HPSSAudio.framesPerPacket)) else {
            throw Failure.decode(-1)
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return self.input
        }
        if status == .error {
            converter.reset()
            throw Failure.decode(error?.code ?? -1)
        }
        guard output.frameLength > 0 else { throw Failure.decode(0) }
        return output
    }

    func reset() { converter.reset() }
}
