// Vicinia — long-term reference picture (LTRP) acknowledgments.
// SPDX-License-Identifier: MIT
//
// When the host's video answer enables LTRP and the stream is HEVC, the client
// confirms the newest stripe-0 (band 0) access unit it has handed to its
// decoder: a standalone RTCP APP packet (PT 204, length 3) from the client's
// own video SSRC whose 32-bit name slot holds the value 5, followed by the
// access unit's 16-bit DONL as a 32-bit big-endian value. At most one
// confirmation follows one batch of media processing (one datagram, one poll),
// carrying the newest such DONL. A media loss, a wait for random access or a
// stream reset drops a confirmation that has not been sent yet.

/// LTRP flag of the video answer: field 7 of the stream description (field 5)
/// of the video blob's negotiator protobuf.
enum LTRPNegotiation: Equatable, Sendable, CustomStringConvertible {
    case enabled
    case disabled
    /// The video answer has no field 5.7 (or no stream description, or is empty).
    case absent(String)
    /// The answer's layout or the video blob cannot be read.
    case unparseable(String)

    var label: String {
        switch self {
        case .enabled: "ENABLED"
        case .disabled: "DISABLED"
        case .absent: "ABSENT"
        case .unparseable: "UNPARSEABLE"
        }
    }
    var description: String {
        switch self {
        case .enabled, .disabled: label
        case .absent(let why), .unparseable(let why): "\(label) (\(why))"
        }
    }
}

/// Codec of the negotiated video stream.
enum VideoCodec: String, Sendable { case hevc, other }

#if (DEBUG && VICINIA_DEVELOPER_TOOLS) || VICINIA_MEASUREMENT_TOOLS
/// The diagnostic switch (`-ltrp-ack on|off`). Off unless exactly "on".
enum ReferenceAcknowledgmentControl: String, Sendable {
    case on, off

    init(launchValue: String?) { self = launchValue == "on" ? .on : .off }
}
#endif

/// Media-queue state of the confirmations (owned by `MediaPipeline`).
struct ReferenceAcknowledgment {
    #if DEBUG || VICINIA_MEASUREMENT_TOOLS
    struct Counters: Sendable, Equatable {
        var noted = 0           // stripe-0 access units handed to decoding while active
        var superseded = 0      // noted while an older one was still waiting (one batch, several units)
        var dropped = 0         // waiting ones dropped by a loss, a random-access wait, a reset or deactivation
        var taken = 0           // handed to the sender
    }
    private(set) var counters = Counters()
    #endif

    private(set) var active = false
    private(set) var pending: UInt16?

    static func gate(answer: LTRPNegotiation, codec: VideoCodec) -> Bool {
        answer == .enabled && codec == .hevc
    }

    mutating func activate(_ on: Bool) {
        drop()
        active = on
    }

    /// An access unit handed to the decoder (released in decode order, random
    /// access reached, decoder ready, picture data present).
    mutating func handedToDecoding(stripe: Int, donl: UInt16?) {
        guard active, stripe == 0, let donl else { return }
        #if DEBUG || VICINIA_MEASUREMENT_TOOLS
        if pending != nil { counters.superseded += 1 }
        counters.noted += 1
        #endif
        pending = donl
    }

    mutating func drop() {
        #if DEBUG || VICINIA_MEASUREMENT_TOOLS
        if pending != nil { counters.dropped += 1 }
        #endif
        pending = nil
    }

    /// The confirmation to send now, once.
    mutating func take() -> UInt16? {
        guard let donl = pending else { return nil }
        pending = nil
        #if DEBUG || VICINIA_MEASUREMENT_TOOLS
        counters.taken += 1
        #endif
        return donl
    }
}
