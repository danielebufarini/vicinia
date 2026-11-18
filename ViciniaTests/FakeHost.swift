// Vicinia tests — a loopback fake HPSS host speaking the type-33 grammar with a
// server-side SRP-6a simulator (vetted OpenSSL arithmetic via BigNum), used to
// drive the real authenticator into its negative paths.
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Security
@testable import Vicinia

final class FakeHost: @unchecked Sendable {
    // Invariant: configured before `start()`, then only read on the listener queue.
    enum Behavior: Sendable, Equatable {
        case valid, corruptM2, wrongGroup, iterations(UInt64), badEnvelope, wrongPassword, noType33
    }

    let behavior: Behavior
    let password: String
    let salt = Array((0..<32).map { UInt8($0 &* 7 &+ 3) })
    let privateKey: SecKey
    let spki: [UInt8]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vicinia.tests.fakehost")
    private(set) var serverSessionKey: [UInt8]?
    /// One entry per SRP proof (c2s2) received: whether it verified.
    let proofs = Recorder<Bool>()
    /// Continues the connection after a valid login (control channel, session key);
    /// set before `start()`. Used by the session-level tests (SessionControlTests).
    var afterAuthentication: (@Sendable (ControlChannel, [UInt8]) async throws -> Void)?

    init(behavior: Behavior, password: String = "correct horse") throws {
        self.behavior = behavior
        self.password = password
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw WireError.invalid("rsa") }
        privateKey = key
        // SubjectPublicKeyInfo around the PKCS#1 RSAPublicKey (270 B for 2048-bit).
        let p = [UInt8](pkcs1)
        spki = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
                0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00] + p
    }

    var fingerprint: String { Crypto.sha256(spki).hex }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false     // only touched on `queue`
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                if case .ready = state, let port = l.port { resumed = true; c.resume(returning: port.rawValue) }
                if case .failed(let e) = state { resumed = true; c.resume(throwing: e) }
            }
            l.newConnectionHandler = { [self] conn in
                let ch = ControlChannel(connection: conn)
                Task { try? await self.serve(ch) }
            }
            l.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func serve(_ ch: ControlChannel) async throws {
        try await ch.open(timeout: .seconds(5))
        try await ch.send(RFB.version)
        _ = try await ch.read(12, timeout: .seconds(5), "banner")
        let types: [UInt8] = behavior == .noType33 ? [30, 36] : [30, 33, 36, 35]
        try await ch.send([UInt8(types.count)] + types)
        if behavior == .noType33 { return }
        _ = try await ch.read(15, timeout: .seconds(5), "key request")
        var kw = ByteWriter(); kw.append([0x00, 0x01]); kw.u32(UInt32(spki.count)); kw.append(spki); kw.u8(0)
        var kp = ByteWriter(); kp.u32(UInt32(kw.bytes.count)); kp.append(kw.bytes)
        try await ch.send(kp.bytes)

        _ = try await ch.read(4, timeout: .seconds(5), "c2s1 length")
        let c2s1 = try await ch.read(650, timeout: .seconds(5), "c2s1")
        var error: Unmanaged<CFError>?
        guard SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(c2s1[10 ..< 266]) as CFData, &error) != nil else {
            return
        }

        // Server SRP state.
        let ctx = try BigNumContext()
        let N = try BigNum(SRPGroup.N), g = try BigNum([5])
        let iterations: UInt64 = { if case .iterations(let n) = behavior { return n }; return 1000 }()
        let verifierPassword = behavior == .wrongPassword ? "a different password" : password
        let x = try SRPClient.derivePrivateKey(salt: salt, iterations: 1000, password: SecretBytes(verifierPassword))
        let v = try g.modExpConstTime(x, N, ctx)
        let b = try BigNum(try Crypto.randomBytes(64))
        let k = try BigNum(Crypto.sha512(SRPGroup.N, try g.padded(512)))
        let B = try (try k.modMul(v, N, ctx)).add(try g.modExpConstTime(b, N, ctx)).mod(N, ctx)
        let bBytes = try B.padded(512)

        var inner = ByteWriter()
        var nBytes = SRPGroup.N
        if behavior == .wrongGroup { nBytes[511] ^= 0x02 }
        inner.u8(0); inner.u16(512); inner.append(nBytes); inner.u16(1); inner.u8(5)
        inner.u8(UInt8(salt.count)); inner.append(salt); inner.u16(512); inner.append(bBytes)
        inner.u64(iterations)
        let options = Array("mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2".utf8)
        inner.u16(UInt16(options.count)); inner.append(options)
        try await ch.send(Self.envelope(step: 2, inner.bytes, badX: behavior == .badEnvelope))
        if [.wrongGroup, .badEnvelope].contains(behavior) || iterations != 1000 { return }

        _ = try await ch.read(4, timeout: .seconds(10), "c2s2 length")
        var r = ByteReader(try await ch.read(1076, timeout: .seconds(10), "c2s2"), offset: 14)
        let aPad = try r.take(Int(try r.u16()))
        let m1 = try r.take(Int(try r.u8()))
        let A = try BigNum(aPad)
        let u = try BigNum(Crypto.sha512(aPad, bBytes))
        let S = try (try A.modMul(try v.modExpConstTime(u, N, ctx), N, ctx)).modExpConstTime(b, N, ctx)
        let K = Crypto.sha512(try S.padded(512))
        let xorNG = zip(Crypto.sha512(SRPGroup.N), Crypto.sha512(try g.padded(512))).map { $0 ^ $1 }
        let expectedM1 = Crypto.sha512(xorNG, Crypto.sha512([]), salt, aPad, bBytes, K)
        proofs.add(expectedM1 == m1)
        guard expectedM1 == m1 else {
            // Rejection exactly as observed from the macOS 27.2.1 host for a wrong
            // password: u32 total=6 | u32 step=2 | u16 x=0 (no payload), nothing after.
            try await ch.send([0, 0, 0, 6, 0, 0, 0, 2, 0, 0])
            return
        }
        serverSessionKey = Array(Crypto.sha256(K).prefix(16))
        var m2 = Crypto.sha512(aPad, m1, K)
        if behavior == .corruptM2 { m2[0] ^= 1 }
        var fin = ByteWriter(); fin.u8(64); fin.append(m2); fin.u8(16); fin.append(try Crypto.randomBytes(16)); fin.u16(0); fin.u32(0)
        var out = Self.envelope(step: 3, fin.bytes, badX: false)
        out += [0, 0, 0, 0]                                  // SecurityResult OK
        try await ch.send(out)
        if let afterAuthentication, let key = serverSessionKey { try await afterAuthentication(ch, key) }
    }

    /// u32 total | u32 step | u16 x | u32 payload_len | payload (observed host framing).
    static func envelope(step: UInt32, _ payload: [UInt8], badX: Bool) -> [UInt8] {
        var w = ByteWriter()
        w.u32(UInt32(10 + payload.count)); w.u32(step); w.u16(UInt16(payload.count + (badX ? 5 : 4)))
        w.u32(UInt32(payload.count)); w.append(payload)
        return w.bytes
    }
}
