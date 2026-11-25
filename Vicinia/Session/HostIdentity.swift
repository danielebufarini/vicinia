// Vicinia — host RSA identity (type-33 envelope key) and its persistent pin.
// SPDX-License-Identifier: MIT
//
// The RSA key only encrypts the identity envelope; it
// has no certificate chain. Vicinia pins SHA-256(DER SubjectPublicKeyInfo)
// per host in the Keychain on explicit first-use acceptance (TOFU) and refuses
// any change unless the user explicitly forgets the pin and re-verifies.

import Foundation
import Security

enum HostKeyError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case notRSA2048
    case encryption(String)
    case changed(pinned: String, presented: String)
    case rejectedByUser
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .malformed(let w): "host key malformed (\(w))"
        case .notRSA2048: "host identity key is not RSA-2048"
        case .encryption(let w): "RSA encryption failed (\(w))"
        case .changed(let p, let n): "host key CHANGED: pinned \(p.prefix(16))…, presented \(n.prefix(16))…"
        case .rejectedByUser: "host key not accepted"
        case .keychain(let s): "Keychain error \(s)"
        }
    }
}

struct HostIdentity {
    let spkiDER: [UInt8]
    let key: SecKey

    var fingerprint: String { Crypto.sha256(spkiDER).hex }

    init(spkiDER der: [UInt8]) throws {
        spkiDER = der
        let pkcs1 = try Self.rsaPublicKeyFromSPKI(der)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, &error) else {
            throw HostKeyError.malformed("SecKeyCreateWithData: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard SecKeyGetBlockSize(key) == 256 else { throw HostKeyError.notRSA2048 }
        self.key = key
    }

    func encryptPKCS1(_ plaintext: [UInt8]) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(plaintext) as CFData, &error) else {
            throw HostKeyError.encryption(error?.takeRetainedValue().localizedDescription ?? "?")
        }
        let out = [UInt8](ct as Data)
        guard out.count == 256 else { throw HostKeyError.encryption("ciphertext \(out.count) B") }
        return out
    }

    /// SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    static func rsaPublicKeyFromSPKI(_ der: [UInt8]) throws -> [UInt8] {
        var r = DERReader(der)
        let spki = try r.element(tag: 0x30)
        guard r.atEnd else { throw HostKeyError.malformed("trailing bytes") }
        var s = DERReader(spki)
        var alg = DERReader(try s.element(tag: 0x30))
        let oid = try alg.element(tag: 0x06)
        guard oid == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01] else {   // rsaEncryption
            throw HostKeyError.notRSA2048
        }
        let bits = try s.element(tag: 0x03)
        guard s.atEnd, bits.first == 0 else { throw HostKeyError.malformed("bit string") }
        return Array(bits.dropFirst())
    }
}

private struct DERReader {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }
    var atEnd: Bool { i == b.count }

    mutating func element(tag: UInt8) throws -> [UInt8] {
        guard i + 2 <= b.count, b[i] == tag else { throw HostKeyError.malformed("tag") }
        i += 1
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard (1...3).contains(n), i + n <= b.count else { throw HostKeyError.malformed("length") }
            len = b[i ..< i + n].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        guard len <= b.count - i else { throw HostKeyError.malformed("length") }
        defer { i += len }
        return Array(b[i ..< i + len])
    }
}

/// Per-host fingerprint pin in the Keychain (this device only).
enum HostKeyPinStore {
    private static let service = "it.danielebufarini.vicinia.host-rsa-pin"

    static func pinned(host: String) throws -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: host, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let data = out as? Data else { throw HostKeyError.keychain(st) }
        return String(decoding: data, as: UTF8.self)
    }

    static func pin(host: String, fingerprint: String) throws {
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: host, kSecValueData: Data(fingerprint.utf8),
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let st = SecItemAdd(item as CFDictionary, nil)
        guard st == errSecSuccess else { throw HostKeyError.keychain(st) }
    }

    /// Explicit user action only ("Forget host key"); never automatic.
    static func forget(host: String) throws {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: host]
        let st = SecItemDelete(q as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw HostKeyError.keychain(st) }
    }
}
