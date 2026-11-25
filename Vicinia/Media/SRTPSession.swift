// Vicinia — libsrtp session wrapper: AES-256-ICM + HMAC-SHA1-80, 32-byte key
// + 14-byte salt, per-SSRC rollover and replay protection.
// SPDX-License-Identifier: MIT

import Foundation

enum SRTPError: Error, Equatable, CustomStringConvertible {
    case setup(UInt32)
    case authentication
    case replay
    case other(UInt32)

    var description: String {
        switch self {
        case .setup(let s): "SRTP setup failed (\(s))"
        case .authentication: "SRTP authentication failure"
        case .replay: "SRTP replay rejected"
        case .other(let s): "SRTP error \(s)"
        }
    }
}

/// One libsrtp context for one direction of one leg. Not thread-safe: owned
/// by the serial media queue.
final class SRTPSession {
    private var ctx: srtp_t?
    static let replayWindow: UInt = 1024
    private static let initialized: UInt32 = srtp_init().rawValue

    /// `keySalt` is the 46-byte blob from the 0x1c offer; `inbound` selects
    /// ssrc_any_inbound (receive) vs ssrc_any_outbound (send).
    init(keySalt: [UInt8], inbound: Bool) throws {
        guard Self.initialized == srtp_err_status_ok.rawValue else { throw SRTPError.setup(Self.initialized) }
        guard keySalt.count == 46 else { throw SRTPError.setup(0) }
        var policy = srtp_policy_t()
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtp)
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtcp)
        policy.ssrc.type = inbound ? ssrc_any_inbound : ssrc_any_outbound
        policy.window_size = Self.replayWindow
        policy.allow_repeat_tx = 0
        var key = keySalt
        let st = key.withUnsafeMutableBufferPointer { k -> srtp_err_status_t in
            policy.key = k.baseAddress
            return srtp_create(&ctx, &policy)
        }
        for i in key.indices { key[i] = 0 }
        guard st == srtp_err_status_ok else { throw SRTPError.setup(st.rawValue) }
    }

    deinit { if let ctx { srtp_dealloc(ctx) } }

    private static func map(_ st: srtp_err_status_t) -> SRTPError {
        switch st {
        case srtp_err_status_auth_fail: .authentication
        case srtp_err_status_replay_fail, srtp_err_status_replay_old: .replay
        default: .other(st.rawValue)
        }
    }

    func unprotectRTP(_ packet: Data) throws -> Data { try transform(packet, extra: 0) { srtp_unprotect(ctx, $0, $1) } }
    func unprotectRTCP(_ packet: Data) throws -> Data { try transform(packet, extra: 0) { srtp_unprotect_rtcp(ctx, $0, $1) } }
    func protectRTP(_ packet: [UInt8]) throws -> Data { try transform(Data(packet), extra: Int(SRTP_MAX_TRAILER_LEN)) { srtp_protect(ctx, $0, $1) } }
    func protectRTCP(_ packet: [UInt8]) throws -> Data {
        try transform(Data(packet), extra: Int(SRTP_MAX_TRAILER_LEN) + 4) { srtp_protect_rtcp(ctx, $0, $1) }
    }

    private func transform(_ packet: Data, extra: Int,
                           _ op: (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> srtp_err_status_t) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: packet.count + extra)
        buffer.replaceSubrange(0 ..< packet.count, with: packet)
        var length = Int32(packet.count)
        let st = buffer.withUnsafeMutableBytes { op($0.baseAddress!, &length) }
        guard st == srtp_err_status_ok else { throw Self.map(st) }
        return Data(buffer.prefix(Int(length)))
    }
}
