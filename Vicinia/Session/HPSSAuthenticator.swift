// Vicinia — RFB security type 33 (RSA1 + Apple SRP-6a) over the control channel.
// SPDX-License-Identifier: MIT
//
// Wire grammar: RSA1 key request, RSA-encrypted identity envelope (c2s1,
// 650 B), SRP challenge, c2s2 (1076 B), final proof. Server envelopes use
// the framing observed on the macOS 27.2.1 host — u32 total | u32 step |
// u16 x | u32 payload_len, with x = payload_len + 4 — exact length checks,
// RSA pin/TOFU, mandatory M2.

import Foundation

enum AuthFailure: Error, Equatable, CustomStringConvertible {
    case typeNotOffered([UInt8])
    case protocolViolation(String)
    case rejected(String)
    case invalidServerProof
    case srp(SRPError)
    case hostKey(HostKeyError)

    var description: String {
        switch self {
        case .typeNotOffered(let t): "host does not offer security type 33 (offered \(t)); no downgrade"
        case .protocolViolation(let w): "authentication protocol violation: \(w)"
        case .rejected(let detail): "host rejected the credentials (\(detail))"
        case .invalidServerProof: "server proof M2 INVALID; session refused"
        case .srp(let e): e.description
        case .hostKey(let e): e.description
        }
    }
}

/// Facts about one authentication, for the evidence log (no secrets).
struct AuthTranscript: Sendable {
    var securityTypes: [UInt8] = []
    var hostKeyFingerprint = ""
    var pinStatus = ""
    var iterations: UInt64 = 0
    var options = ""
    var challengeFraming = ""
    var proofFraming = ""
    var m2Verified = false
    /// Raw host bytes after c2s2 when no proof envelope came (a failure notice; no secrets).
    var rejectionWire = ""
}

struct HPSSAuthenticator {
    let channel: ControlChannel
    let host: String
    /// Asks the user to accept a not-yet-pinned host key (TOFU). Must not auto-accept.
    let trustOnFirstUse: @Sendable (_ host: String, _ fingerprint: String) async -> Bool
    static let step: Duration = .seconds(15)

    /// Runs the version exchange and type-33 authentication. Returns the
    /// initial record-layer wrap key SHA-256(K)[0..<16] after M2 verification.
    func run(username: String, password: SecretBytes, transcript: inout AuthTranscript) async throws -> [UInt8] {
        let banner = try await channel.read(12, timeout: Self.step, "RFB banner")
        guard banner == RFB.version else { throw AuthFailure.protocolViolation("banner \(String(decoding: banner, as: UTF8.self))") }
        try await channel.send(RFB.version)
        let n = Int(try await channel.read(1, timeout: Self.step, "security type count")[0])
        guard n > 0 else { throw AuthFailure.protocolViolation("no security types") }
        let types = try await channel.read(n, timeout: Self.step, "security types")
        transcript.securityTypes = types
        guard types.contains(RFB.securityTypeRSA1SRP) else { throw AuthFailure.typeNotOffered(types) }

        // RSA1 key request (authtype 0) and the host's DER SubjectPublicKeyInfo.
        try await channel.send([0x21, 0, 0, 0, 0x0A, 0x01, 0x00] + Array("RSA1".utf8) + [0, 0, 0, 0])
        let keyPacket = try await readLengthPrefixed(max: 4096, "RSA key response")
        var kr = ByteReader(keyPacket)
        try kr.skip(2, "key prefix")
        let derLength = Int(try kr.u32("key length"))
        guard derLength > 0, derLength <= kr.remaining else { throw AuthFailure.protocolViolation("RSA key length") }
        let identity: HostIdentity
        do { identity = try HostIdentity(spkiDER: try kr.take(derLength)) } catch let e as HostKeyError { throw AuthFailure.hostKey(e) }
        transcript.hostKeyFingerprint = identity.fingerprint
        transcript.pinStatus = try await checkPin(identity.fingerprint)

        // c2s1: RSA-encrypted identity envelope in the "modulus" slot.
        let user = Array(username.utf8)
        var inner = ByteWriter(); inner.u32(UInt32(user.count)); inner.append(user); inner.zeros(3)
        var envelope = ByteWriter(); envelope.u32(UInt32(inner.bytes.count)); envelope.append(inner.bytes)
        let encrypted: [UInt8]
        do { encrypted = try identity.encryptPKCS1(envelope.bytes) } catch let e as HostKeyError { throw AuthFailure.hostKey(e) }
        var c2s1 = ByteWriter(capacity: 654)
        c2s1.u32(650); c2s1.append([0x01, 0x00]); c2s1.append(Array("RSA1".utf8)); c2s1.append([0x00, 0x02])
        c2s1.u16(256); c2s1.append(encrypted); c2s1.zeros(384)
        try await channel.send(c2s1.bytes)

        // SRP challenge.
        let challengeEnvelope = try await readServerEnvelope(min: 600, max: 8192, "SRP challenge")
        transcript.challengeFraming = challengeEnvelope.framing
        let challenge = try Self.parseChallenge(challengeEnvelope.inner)
        transcript.iterations = challenge.iterations
        transcript.options = String(decoding: challenge.options, as: UTF8.self)
        let proof: SRPProof
        do { proof = try SRPClient.respond(to: challenge, password: password) } catch let e as SRPError { throw AuthFailure.srp(e) }

        // c2s2: A, M1, options echo, client random; padded to 1076.
        var sd = ByteWriter(capacity: 700)
        sd.u16(512); sd.append(proof.A); sd.u8(64); sd.append(proof.M1)
        sd.u16(UInt16(challenge.options.count)); sd.append(challenge.options)
        sd.u8(16); sd.append(try Crypto.randomBytes(16))
        var pay = ByteWriter(capacity: 1076)
        pay.append([0x01, 0x00]); pay.append(Array("RSA1".utf8)); pay.append([0x00, 0x02])
        pay.u16(UInt16(sd.bytes.count + 4)); pay.u32(UInt32(sd.bytes.count)); pay.append(sd.bytes)
        guard pay.bytes.count <= 1076 else { throw AuthFailure.protocolViolation("c2s2 too long") }
        pay.zeros(1076 - pay.bytes.count)
        var c2s2 = ByteWriter(capacity: 1080); c2s2.u32(1076); c2s2.append(pay.bytes)
        try await channel.send(c2s2.bytes)

        // Final proof (or a failing SecurityResult), then SecurityResult.
        let total = try await channel.read(4, timeout: Self.step, "final proof length")
        let totalLength = Int(total.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        if totalLength < 10 + 2 + 64 {
            // Too short to carry M2: the host refused. Observed on macOS 27.2.1
            // for a wrong password: total = 6, body = u32 step | u16 x(=0) — an
            // envelope without payload — and nothing after it. Record the exact
            // bytes (a failure notice; no secrets), then refuse.
            let body = (try? await channel.readAvailable(max: totalLength + 64, timeout: .milliseconds(500))) ?? []
            transcript.rejectionWire = (total + body).hex
            throw AuthFailure.rejected(Self.describeFailure(body, declared: totalLength))
        }
        guard totalLength <= 4096 else { throw AuthFailure.protocolViolation("final proof length \(totalLength)") }
        let proofEnvelope = try Self.parseEnvelope(try await channel.read(totalLength, timeout: Self.step, "final proof"),
                                                   "final proof")
        transcript.proofFraming = proofEnvelope.framing
        var pr = ByteReader(proofEnvelope.inner)
        guard try pr.u8("M2 length") == 64 else { throw AuthFailure.protocolViolation("M2 length") }
        let m2 = try pr.take(64, "M2")
        let randomLength = Int(try pr.u8("server random length"))
        try pr.skip(randomLength, "server random")
        let result = try await channel.read(4, timeout: Self.step, "SecurityResult").reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard result == 0 else {
            let reason = try? await readFailureReason()
            throw AuthFailure.rejected("SecurityResult \(result)" + (reason.map { ": \($0)" } ?? ""))
        }
        guard Crypto.constantTimeEqual(m2, proof.expectedM2) else { throw AuthFailure.invalidServerProof }
        transcript.m2Verified = true
        return proof.sessionKey
    }

    private func checkPin(_ fingerprint: String) async throws -> String {
        let pinned: String?
        do { pinned = try HostKeyPinStore.pinned(host: host) } catch let e as HostKeyError { throw AuthFailure.hostKey(e) }
        if let pinned {
            guard Crypto.constantTimeEqual(Array(pinned.utf8), Array(fingerprint.utf8)) else {
                throw AuthFailure.hostKey(.changed(pinned: pinned, presented: fingerprint))
            }
            return "matches Keychain pin"
        }
        guard await trustOnFirstUse(host, fingerprint) else { throw AuthFailure.hostKey(.rejectedByUser) }
        do { try HostKeyPinStore.pin(host: host, fingerprint: fingerprint) } catch let e as HostKeyError { throw AuthFailure.hostKey(e) }
        return "pinned on explicit first-use acceptance (TOFU)"
    }

    private func readLengthPrefixed(max: Int, _ what: String) async throws -> [UInt8] {
        let lb = try await channel.read(4, timeout: Self.step, what)
        let n = Int(lb.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard n > 0, n <= max else { throw AuthFailure.protocolViolation("\(what) length \(n)") }
        return try await channel.read(n, timeout: Self.step, what)
    }

    private func readServerEnvelope(min: Int, max: Int, _ what: String) async throws -> (inner: [UInt8], framing: String) {
        let body = try await readLengthPrefixed(max: max, what)
        guard body.count >= min else { throw AuthFailure.protocolViolation("\(what) too short (\(body.count) B)") }
        return try Self.parseEnvelope(body, what)
    }

    /// RFC 6143 failure reason after a non-zero SecurityResult (best effort, bounded).
    private func readFailureReason() async throws -> String? {
        guard let lb = try await channel.peek(4, timeout: .milliseconds(500)) else { return nil }
        let n = Int(lb.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard n > 0, n <= 1024 else { return nil }
        _ = try await channel.read(4, timeout: .seconds(1), "reason length")
        return String(decoding: try await channel.read(n, timeout: .seconds(1), "reason"), as: UTF8.self)
    }

    /// Best-effort, bounded description of a host failure notice (bytes kept verbatim in the transcript).
    static func describeFailure(_ body: [UInt8], declared: Int) -> String {
        if declared == 6, body.count >= 6 {
            let step = body[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let x = UInt16(body[4]) << 8 | UInt16(body[5])
            if x == 0 { return "empty proof envelope: step=\(step) x=0, no server proof" + (body.count > 6 ? ", +\(body.count - 6) B" : "") }
        }
        let printable = String(decoding: body.filter { (0x20..<0x7F).contains($0) }, as: UTF8.self)
        return "\(declared)-byte notice without proof" + (printable.count >= 4 ? " \"\(printable)\"" : "")
    }

    /// u32 step | u16 x | u32 payload_len | payload, x = payload_len + 4, payload filling the body.
    static func parseEnvelope(_ body: [UInt8], _ what: String) throws -> (inner: [UInt8], framing: String) {
        var r = ByteReader(body)
        let step = try r.u32("\(what) step"), x = try r.u16("\(what) x"), plen = try r.u32("\(what) payload length")
        let framing = "total=\(body.count) step=\(step) x=\(x) payload_len=\(plen)"
        guard Int(plen) == r.remaining, Int(x) == Int(plen) + 4 else {
            throw AuthFailure.protocolViolation("\(what) envelope framing: \(framing)")
        }
        return (try r.take(Int(plen)), framing)
    }

    /// %c control | %m N | %m g | %o salt | %m B | %q iterations | %s options
    static func parseChallenge(_ inner: [UInt8]) throws -> SRPChallenge {
        var r = ByteReader(inner)
        guard try r.u8("control") == 0 else { throw AuthFailure.protocolViolation("challenge control byte") }
        let N = try r.take(Int(try r.u16("N length")), "N")
        let g = try r.take(Int(try r.u16("g length")), "g")
        let salt = try r.take(Int(try r.u8("salt length")), "salt")
        let B = try r.take(Int(try r.u16("B length")), "B")
        let iterations = try r.u64("iterations")
        let options = try r.take(Int(try r.u16("options length")), "options")
        return SRPChallenge(N: N, g: g, salt: salt, B: B, iterations: iterations, options: options)
    }
}
