// Vicinia — Apple SRP-6a client for RFB security type 33 (RSA1/SRP).
// SPDX-License-Identifier: MIT
//
// Apple SRP-6a formulas with exact RFC 5054 group and parameter validation,
// constant-time secret exponentiation via OpenSSL BN_mod_exp_mont_consttime,
// mandatory M2 verification.
// Big-integer arithmetic is OpenSSL libcrypto; hashes/PBKDF2 are CommonCrypto.

import Foundation

enum SRPError: Error, Equatable, CustomStringConvertible {
    case group, generator, salt, publicValue, iterations, options, degenerate, bignum, credentials

    var description: String {
        switch self {
        case .group: "SRP group is not the RFC 5054 4096-bit group"
        case .generator: "SRP generator is not 5"
        case .salt: "SRP salt length invalid"
        case .publicValue: "SRP public value B invalid"
        case .iterations: "PBKDF2 iteration count outside 1…1,000,000"
        case .options: "SRP options invalid"
        case .degenerate: "SRP computation degenerate (u or base is zero)"
        case .bignum: "big-integer operation failed"
        case .credentials: "credentials no longer available (already used, or the session was closed)"
        }
    }
}

enum SRPGroup {
    /// RFC 5054 Appendix A, 4096-bit group, verified against the RFC closed form.
    static let N: [UInt8] = hexBytes(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
        + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
        + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
        + "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
        + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
        + "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
        + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
        + "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7"
        + "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6"
        + "287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9"
        + "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF")
    static let g: UInt8 = 5
    static let length = 512
    static let maxIterations: UInt64 = 1_000_000

    static func hexBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](), chars = Array(s.utf8), i = 0
        while i + 1 < chars.count {
            out.append(UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16)!)
            i += 2
        }
        return out
    }
}

/// The server's SRP challenge after framing validation.
struct SRPChallenge {
    var N: [UInt8]
    var g: [UInt8]
    var salt: [UInt8]
    var B: [UInt8]          // exactly as sent (used unpadded in u and M1, as the working client does)
    var iterations: UInt64
    var options: [UInt8]

    func validate() throws {
        guard N == SRPGroup.N else { throw SRPError.group }
        guard g == [SRPGroup.g] else { throw SRPError.generator }
        guard salt.count >= 16 else { throw SRPError.salt }
        guard (1...SRPGroup.length).contains(B.count) else { throw SRPError.publicValue }
        guard (1...SRPGroup.maxIterations).contains(iterations) else { throw SRPError.iterations }
        guard options.count <= 256, String(decoding: options, as: UTF8.self).contains("mda=SHA-512") else {
            throw SRPError.options
        }
    }
}

struct SRPProof {
    let A: [UInt8]            // PAD(A), 512 bytes
    let M1: [UInt8]
    let expectedM2: [UInt8]
    let sessionKey: [UInt8]   // SHA-256(K)[0..<16]: initial record-layer wrap key
}

/// Owning wrapper around an OpenSSL BIGNUM (cleared on release) exposing only
/// the vetted libcrypto operations SRP needs. Not thread-safe; one per use.
final class BigNum {
    let p: OpaquePointer
    init() throws {
        guard let p = BN_new() else { throw SRPError.bignum }
        self.p = p
    }
    convenience init(_ bytes: [UInt8]) throws {
        try self.init()
        guard bytes.withUnsafeBufferPointer({ BN_bin2bn($0.baseAddress, Int32($0.count), p) }) != nil else {
            throw SRPError.bignum
        }
    }
    deinit { BN_clear_free(p) }
    var isZero: Bool { BN_is_zero(p) != 0 }
    func padded(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        guard BN_bn2binpad(p, &out, Int32(n)) == Int32(n) else { throw SRPError.bignum }
        return out
    }
    func setConstTime() { BN_set_flags(p, Int32(BN_FLG_CONSTTIME)) }

    /// self^e mod m with OpenSSL's constant-time Montgomery exponentiation.
    func modExpConstTime(_ e: BigNum, _ m: BigNum, _ ctx: BigNumContext) throws -> BigNum {
        let r = try BigNum()
        e.setConstTime()
        guard BN_mod_exp_mont_consttime(r.p, p, e.p, m.p, ctx.p, nil) == 1 else { throw SRPError.bignum }
        return r
    }
    func modMul(_ b: BigNum, _ m: BigNum, _ ctx: BigNumContext) throws -> BigNum {
        let r = try BigNum()
        guard BN_mod_mul(r.p, p, b.p, m.p, ctx.p) == 1 else { throw SRPError.bignum }
        return r
    }
    func modSub(_ b: BigNum, _ m: BigNum, _ ctx: BigNumContext) throws -> BigNum {
        let r = try BigNum()
        guard BN_mod_sub(r.p, p, b.p, m.p, ctx.p) == 1 else { throw SRPError.bignum }
        return r
    }
    func mod(_ m: BigNum, _ ctx: BigNumContext) throws -> BigNum {
        let r = try BigNum()
        guard BN_nnmod(r.p, p, m.p, ctx.p) == 1 else { throw SRPError.bignum }
        return r
    }
    func mul(_ b: BigNum, _ ctx: BigNumContext) throws -> BigNum {
        let r = try BigNum()
        guard BN_mul(r.p, p, b.p, ctx.p) == 1 else { throw SRPError.bignum }
        return r
    }
    func add(_ b: BigNum) throws -> BigNum {
        let r = try BigNum()
        guard BN_add(r.p, p, b.p) == 1 else { throw SRPError.bignum }
        return r
    }
}

final class BigNumContext {
    let p: OpaquePointer
    init() throws {
        guard let p = BN_CTX_new() else { throw SRPError.bignum }
        self.p = p
    }
    deinit { BN_CTX_free(p) }
}

enum SRPClient {
    /// Computes A, M1, the expected M2 and the session key. `secretA` is only
    /// injected by tests; production draws 64 bytes from SecRandomCopyBytes.
    static func respond(to c: SRPChallenge, password: SecretBytes, secretA: [UInt8]? = nil) throws -> SRPProof {
        try c.validate()
        let ctx = try BigNumContext()
        let L = SRPGroup.length
        let N = try BigNum(c.N), g = try BigNum(c.g)
        let gPad = try g.padded(L)

        // Reject B ≡ 0 (mod N).
        let bMod = try BigNum(c.B).mod(N, ctx)
        guard !bMod.isZero else { throw SRPError.publicValue }

        // x = H(salt || H(":" || PBKDF2-HMAC-SHA512(P, salt, iterations, 128)))
        let x = try derivePrivateKey(salt: c.salt, iterations: c.iterations, password: password)

        let a = try BigNum(try secretA ?? Crypto.randomBytes(64))
        guard !a.isZero else { throw SRPError.degenerate }
        let aPad = try g.modExpConstTime(a, N, ctx).padded(L)

        let k = try BigNum(Crypto.sha512(c.N, gPad))
        let u = try BigNum(Crypto.sha512(aPad, c.B))
        guard !u.isZero else { throw SRPError.degenerate }

        // S = (B − k·g^x)^(a + u·x) mod N, secret exponents constant-time.
        let base = try bMod.modSub(try k.modMul(try g.modExpConstTime(x, N, ctx), N, ctx), N, ctx)
        guard !base.isZero else { throw SRPError.degenerate }
        let S = try base.modExpConstTime(try a.add(try u.mul(x, ctx)), N, ctx)

        let K = Crypto.sha512(try S.padded(L))
        let xorNG = zip(Crypto.sha512(c.N), Crypto.sha512(gPad)).map { $0 ^ $1 }
        let M1 = Crypto.sha512(xorNG, Crypto.sha512([]), c.salt, aPad, c.B, K)
        let M2 = Crypto.sha512(aPad, M1, K)
        return SRPProof(A: aPad, M1: M1, expectedM2: M2, sessionKey: Array(Crypto.sha256(K).prefix(16)))
    }

    /// Apple SALTED-SHA512-PBKDF2: x = H(salt || H(":" || PBKDF2(P, salt, it, 128))). Consumes the
    /// password (its single use); a password already used or wiped by teardown derives nothing.
    static func derivePrivateKey(salt: [UInt8], iterations: UInt64, password: SecretBytes) throws -> BigNum {
        guard (1...SRPGroup.maxIterations).contains(iterations) else { throw SRPError.iterations }
        guard let dk = try password.consume({
            try Crypto.pbkdf2SHA512(password: $0, salt: salt, rounds: UInt32(iterations), length: 128)
        }) else { throw SRPError.credentials }
        return try BigNum(Crypto.sha512(salt, Crypto.sha512(Array(":".utf8), dk)))
    }
}
