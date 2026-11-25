// Vicinia — Apple RFB encrypted record layer ("enc1103"), fail-closed.
// SPDX-License-Identifier: MIT
//
// Encrypted-record wire format ("enc1103"): AES-128-CBC with one persistent context per
// direction, plaintext = u16 body_len | body | filler | SHA-1(u32 seq | …).
// Exact expected sequence number, constant-time trailer check, bounded
// body/filler; any failure is fatal.

import Foundation

enum RecordError: Error, Equatable, CustomStringConvertible {
    case framing(Int)
    case integrity(seq: UInt32)
    case body
    case rekey

    var description: String {
        switch self {
        case .framing(let n): "record framing length \(n) invalid"
        case .integrity(let s): "record integrity failure at sequence \(s)"
        case .body: "record body length inconsistent"
        case .rekey: "rekey payload unusable"
        }
    }
}

/// Owned by the session actor (not thread-safe by itself).
final class RecordLayer {
    static let macLength = 20
    static let maxRecordBody = 65_520 - 2 - macLength       // 65,498

    private var encryptor: AESCBCStream
    private var decryptor: AESCBCStream
    private(set) var wrapKey: [UInt8]
    private(set) var sendSequence: UInt32 = 0
    private(set) var receiveSequence: UInt32 = 0
    private(set) var rekeys = 0

    /// `rekey` is the 36-byte 0x44f/1103 payload: u32 generation | E(key) | E(iv).
    init(rekey: [UInt8], wrapKey: [UInt8]) throws {
        let (key, iv) = try Self.unwrap(rekey, wrapKey: wrapKey)
        encryptor = try AESCBCStream(encrypt: true, key: key, iv: iv)
        decryptor = try AESCBCStream(encrypt: false, key: key, iv: iv)
        self.wrapKey = key
        rekeys = 1
    }

    /// A later rekey: the new key becomes the CBC key and the next
    /// wrap key, the new IV the CBC IV in both directions; sequence counters
    /// continue. An unusable payload is fatal.
    func rotate(rekey: [UInt8]) throws {
        let (key, iv) = try Self.unwrap(rekey, wrapKey: wrapKey)
        encryptor = try AESCBCStream(encrypt: true, key: key, iv: iv)
        decryptor = try AESCBCStream(encrypt: false, key: key, iv: iv)
        wrapKey = key
        rekeys += 1
    }

    private static func unwrap(_ blob: [UInt8], wrapKey: [UInt8]) throws -> ([UInt8], [UInt8]) {
        guard blob.count == 36, wrapKey.count == 16 else { throw RecordError.rekey }
        let key = try Crypto.aesECBDecryptBlock(key: wrapKey, block: Array(blob[4..<20]))
        let iv = try Crypto.aesECBDecryptBlock(key: wrapKey, block: Array(blob[20..<36]))
        return (key, iv)
    }

    /// Encrypts one control message (split across records if it is larger
    /// than one record body). Returns wire bytes.
    func seal(_ message: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        var start = 0
        repeat {
            let end = min(message.count, start + Self.maxRecordBody)
            out += try sealRecord(Array(message[start..<end]))
            start = end
        } while start < message.count
        return out
    }

    private func sealRecord(_ body: [UInt8]) throws -> [UInt8] {
        let filler = (16 - (2 + body.count + Self.macLength) % 16) % 16
        var framed = ByteWriter(capacity: 2 + body.count + filler + Self.macLength)
        framed.u16(UInt16(body.count))
        framed.append(body)
        framed.append(try Crypto.randomBytes(filler))       // random filler
        var seq = ByteWriter(); seq.u32(sendSequence)
        let plaintext = framed.bytes + Crypto.sha1(seq.bytes, framed.bytes)
        let ciphertext = try encryptor.update(plaintext)
        sendSequence &+= 1
        var w = ByteWriter(capacity: 2 + ciphertext.count)
        w.u16(UInt16(ciphertext.count))
        w.append(ciphertext)
        return w.bytes
    }

    /// Validates an outer record length before reading its ciphertext.
    static func validateLength(_ n: Int) throws {
        guard n >= 32, n % 16 == 0, n <= 65_520 else { throw RecordError.framing(n) }
    }

    /// Decrypts and authenticates one record; returns its body.
    func open(_ ciphertext: [UInt8]) throws -> [UInt8] {
        try Self.validateLength(ciphertext.count)
        let plaintext = try decryptor.update(ciphertext)
        let split = plaintext.count - Self.macLength
        var seq = ByteWriter(); seq.u32(receiveSequence)
        let expected = Crypto.sha1(seq.bytes, Array(plaintext[..<split]))
        guard Crypto.constantTimeEqual(expected, Array(plaintext[split...])) else {
            throw RecordError.integrity(seq: receiveSequence)
        }
        let bodyLength = Int(plaintext[0]) << 8 | Int(plaintext[1])
        let filler = split - 2 - bodyLength
        guard filler >= 0, filler < 16 else { throw RecordError.body }
        receiveSequence &+= 1
        return Array(plaintext[2 ..< 2 + bodyLength])
    }
}
