// Vicinia — thin wrappers over Apple CommonCrypto / Security primitives.
// SPDX-License-Identifier: MIT
// No cryptographic primitive is implemented here; every operation is a
// CommonCrypto or Security framework call.

import CommonCrypto
import Foundation
import Security
import Synchronization

enum CryptoError: Error, Equatable {
    case random(OSStatus)
    case cipher(Int32)
    case kdf(Int32)
}

enum Crypto {
    static func randomBytes(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        let st = SecRandomCopyBytes(kSecRandomDefault, n, &out)
        guard st == errSecSuccess else { throw CryptoError.random(st) }
        return out
    }

    static func sha512(_ parts: [UInt8]...) -> [UInt8] {
        var ctx = CC_SHA512_CTX()
        CC_SHA512_Init(&ctx)
        for p in parts { p.withUnsafeBytes { _ = CC_SHA512_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) } }
        var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512_Final(&out, &ctx)
        return out
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &out) }
        return out
    }

    /// SHA-1 as used by the Apple record-layer trailer (not a MAC).
    static func sha1(_ parts: [UInt8]...) -> [UInt8] {
        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)
        for p in parts { p.withUnsafeBytes { _ = CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) } }
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&out, &ctx)
        return out
    }

    static func pbkdf2SHA512(password: [UInt8], salt: [UInt8], rounds: UInt32, length: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let st = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: Int8.self) { pwc in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc.baseAddress, pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                     rounds, &out, length)
            }
        }
        guard st == Int32(kCCSuccess) else { throw CryptoError.kdf(st) }
        return out
    }

    /// AES-128 single-block ECB decryption (rekey unwrap).
    static func aesECBDecryptBlock(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        precondition(key.count == 16 && block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         key, 16, nil, block, 16, &out, 16, &moved)
        guard st == Int32(kCCSuccess), moved == 16 else { throw CryptoError.cipher(st) }
        return out
    }

    static func aesECBEncryptBlock(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        precondition(key.count == 16 && block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         key, 16, nil, block, 16, &out, 16, &moved)
        guard st == Int32(kCCSuccess), moved == 16 else { throw CryptoError.cipher(st) }
        return out
    }

    /// Constant-time equality for equal-length secrets/proofs.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Persistent AES-128-CBC context (no padding) for one record-layer direction.
/// CBC state chains across calls, as the Apple record layer requires.
final class AESCBCStream {
    private var ref: CCCryptorRef?

    init(encrypt: Bool, key: [UInt8], iv: [UInt8]) throws {
        precondition(key.count == 16 && iv.count == 16)
        let st = CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                 0, key, 16, iv, &ref)
        guard st == Int32(kCCSuccess) else { throw CryptoError.cipher(st) }
    }

    deinit { if let ref { CCCryptorRelease(ref) } }

    func update(_ input: [UInt8]) throws -> [UInt8] {
        precondition(input.count % 16 == 0)
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let st = CCCryptorUpdate(ref, input, input.count, &out, out.count, &moved)
        guard st == Int32(kCCSuccess), moved == input.count else { throw CryptoError.cipher(st) }
        return out
    }
}

/// Holds a password until its single use; never logged or persisted.
///
/// Ownership invariant: the bytes leave this container at most once, by a
/// move made under the lock. Whoever takes them — `consume` for the one
/// derivation, `wipe()` for teardown and deinit — is from then on their only
/// owner and zeroes them when done; every other caller, concurrent or later,
/// finds nothing. Teardown therefore cannot zero storage a derivation is
/// reading, and a derivation cannot read storage teardown has zeroed.
/// Zeroing is best effort: it covers this copy, not what CommonCrypto or
/// the caller derive from it.
final class SecretBytes: Sendable {
    private let storage: Mutex<[UInt8]?>
    init(_ string: String) { storage = Mutex(Array(string.utf8)) }
    init(bytes: [UInt8]) { storage = Mutex(bytes) }

    /// The single use: lends the bytes to `body`, then zeroes them. Returns nil
    /// without calling `body` when they were already used or wiped.
    func consume<R>(_ body: ([UInt8]) throws -> R) rethrows -> R? {
        // Bound straight from the lock's result: `bytes` is the only reference
        // to the storage, so the zeroing below writes in place (no copy-on-write).
        guard var bytes = storage.withLock({ stored in
            defer { stored = nil }
            return stored
        }) else { return nil }
        defer { for i in bytes.indices { bytes[i] = 0 } }
        return try body(bytes)
    }

    func wipe() { _ = consume { _ in } }
    deinit { wipe() }
}
