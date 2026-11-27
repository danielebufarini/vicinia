// Vicinia — clipboard representation adapter between the native Mac
// pasteboard archive and the local pasteboard. Pure and nonisolated: it runs
// off the main actor and never decodes image pixels.
// SPDX-License-Identifier: MIT
//
// Shareable representations (both directions, original bytes, no lossy
// conversion): UTF-8 text, URL, RTF, HTML and PNG/JPEG/TIFF/HEIC/GIF images.
// Explicit compatible fallbacks: UTF-16 text becomes UTF-8 text, a URL also
// travels as text. Everything else (file URLs, private and dynamic types,
// promises) is dropped; content with nothing shareable is `.unsupported` and
// never replaces a valid pasteboard.

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One local pasteboard item: UTI → bytes.
typealias ClipboardItem = [String: Data]

/// Ephemeral session dedup memory: per item, type → SHA-256 of its bytes.
/// Never persisted or logged.
struct ClipboardFingerprint: Equatable, Sendable {
    let items: [[String: [UInt8]]]

    init(_ items: [ClipboardItem]) {
        self.items = items.map { $0.mapValues { Array(SHA256.hash(data: $0)) } }
    }

    /// Every representation of `self` is present, identical, in `other`
    /// (the Mac may add representations of its own to an echoed copy).
    func isCovered(by other: ClipboardFingerprint) -> Bool {
        items.count == other.items.count && zip(items, other.items).allSatisfy { mine, theirs in
            mine.allSatisfy { theirs[$0.key] == $0.value }
        }
    }
}

enum ClipboardFormats {
    static let text = UTType.utf8PlainText.identifier
    static let utf16 = "public.utf16-plain-text"
    static let url = UTType.url.identifier
    static let rtf = UTType.rtf.identifier
    static let html = UTType.html.identifier
    static let images: Set<String> = [UTType.png, .jpeg, .tiff, .heic, .gif].reduce(into: []) { $0.insert($1.identifier) }
    /// Already-compressed image types: one of these is preferred, in the
    /// provider's own fidelity order, over TIFF (uncompressed, often a conversion).
    static let compressedImages: Set<String> = images.subtracting([UTType.tiff.identifier])
    static let shareable: Set<String> = images.union([text, url, rtf, html])
    /// Accepted local text spellings, mapped to UTF-8 text.
    static let localText: [String] = [text, UTType.plainText.identifier, UTType.text.identifier]
    /// What the system paste control may offer for an explicit send.
    static let pasteTypes: [UTType] = [.utf8PlainText, .plainText, .url, .rtf, .html, .png, .jpeg, .tiff, .heic, .gif]

    // MARK: directions

    /// Local items → wire items. `.empty`: nothing at all; `.unsupported`: nothing shareable.
    static func outbound(_ local: [ClipboardItem], limits: ClipboardLimits = .standard) throws(ClipboardIssue) -> [ClipboardWire.Item] {
        let items = try shareableItems(local, limits: limits)
        return items.map { item in
            ClipboardWire.Item(flavors: item.keys.sorted().map { ClipboardWire.Flavor(type: $0, data: [UInt8](item[$0]!)) })
        }
    }

    /// Wire items → local items.
    static func inbound(_ wire: [ClipboardWire.Item], limits: ClipboardLimits = .standard) throws(ClipboardIssue) -> [ClipboardItem] {
        guard wire.contains(where: { !$0.flavors.isEmpty }) else { throw .empty }
        let local = wire.map { item in
            item.flavors.reduce(into: ClipboardItem()) { map, flavor in
                // A zero-length flavor is a promise without data: never used.
                if !flavor.data.isEmpty, map[flavor.type] == nil { map[flavor.type] = Data(flavor.data) }
            }
        }
        // Content exists on the Mac, but only as promises: nothing usable arrived.
        guard local.contains(where: { !$0.isEmpty }) else { throw .unsupported }
        return try shareableItems(local, limits: limits)
    }

    /// Complete inbound path for one 0x1f message, for a background task.
    static func decodeInbound(_ message: [UInt8], limits: ClipboardLimits = .standard)
        -> Result<(items: [ClipboardItem], fingerprint: ClipboardFingerprint), ClipboardIssue> {
        do throws(ClipboardIssue) {
            let items = try inbound(try ClipboardWire.decode(message, limits: limits), limits: limits)
            return .success((items, ClipboardFingerprint(items)))
        } catch { return .failure(error) }
    }

    struct Outbound: Sendable {
        let message: [UInt8]
        let fingerprint: ClipboardFingerprint
        /// Too large with its images: sent with its other representations only (disclosed).
        let omittedImages: Bool
    }

    /// Complete outbound path: the 0x1f message and the fingerprint of what it
    /// carries. A message that is too large only because of its images is sent
    /// with its text representations instead, with a notice about omitted images.
    static func encodeOutbound(_ local: [ClipboardItem], limits: ClipboardLimits = .standard, maxMessage: Int)
        -> Result<Outbound, ClipboardIssue> {
        func package(_ wire: [ClipboardWire.Item], omitted: Bool) throws(ClipboardIssue) -> Outbound {
            let message = try ClipboardWire.encode(wire, limits: limits, maxMessage: maxMessage)
            let shared = wire.map { $0.flavors.reduce(into: ClipboardItem()) { $0[$1.type] = Data($1.data) } }
            return Outbound(message: message, fingerprint: ClipboardFingerprint(shared), omittedImages: omitted)
        }
        let wire: [ClipboardWire.Item]
        do throws(ClipboardIssue) { wire = try outbound(local, limits: limits) } catch { return .failure(error) }
        do throws(ClipboardIssue) {
            return .success(try package(wire, omitted: false))
        } catch {
            let reduced = wire.map { ClipboardWire.Item(flavors: $0.flavors.filter { !images.contains($0.type) }) }
                .filter { !$0.flavors.isEmpty }
            guard case .tooLarge = error, !reduced.isEmpty, reduced != wire else { return .failure(error) }
            do throws(ClipboardIssue) { return .success(try package(reduced, omitted: true)) } catch { return .failure(error) }
        }
    }

    // MARK: normalization

    static func shareableItems(_ local: [ClipboardItem], limits: ClipboardLimits) throws(ClipboardIssue) -> [ClipboardItem] {
        guard local.contains(where: { !$0.isEmpty }) else { throw .empty }
        guard local.count <= limits.items else { throw .tooManyItems(limit: limits.items) }
        let total = local.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        guard total <= limits.archive else { throw .tooLarge(bytes: total, limit: limits.archive) }
        let kept = local.compactMap { normalize($0, limits: limits) }
        guard !kept.isEmpty else { throw .unsupported }
        return kept
    }

    /// The shareable representations of one item with explicit fallbacks, or nil.
    static func normalize(_ item: ClipboardItem, limits: ClipboardLimits) -> ClipboardItem? {
        var out = ClipboardItem()
        if let text = localText.lazy.compactMap({ item[$0] }).first(where: { String(data: $0, encoding: .utf8) != nil }) {
            out[Self.text] = text
        } else if let wide = item[utf16], let string = String(data: wide, encoding: .utf16LittleEndian) {
            out[Self.text] = Data(string.utf8)                      // compatible fallback
        }
        if let data = item[url], let link = webURL(data) {
            out[url] = Data(link.utf8)
            if out[Self.text] == nil { out[Self.text] = Data(link.utf8) } // compatible text fallback
        }
        if let data = item[rtf], data.starts(with: Array("{\\rtf".utf8)) { out[rtf] = data }
        if let data = item[html], !data.isEmpty { out[html] = data }
        for type in images { if let data = item[type], validImage(data, type: type, limits: limits) { out[type] = data } }
        return out.isEmpty ? nil : out
    }

    /// A URL with a scheme other than `file`: remote file URLs are never local paths.
    static func webURL(_ data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme != "file" else { return nil }
        return string
    }

    private static var headerOnly: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// Reads only the image header: type, frame count and pixel dimensions.
    static func validImage(_ data: Data, type: String, limits: ClipboardLimits) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, headerOnly) else { return false }
        return validImage(source, type: type, limits: limits)
    }

    /// The same check on a file, before its bytes are read into memory.
    static func validImage(at url: URL, type: String, limits: ClipboardLimits) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, headerOnly) else { return false }
        return validImage(source, type: type, limits: limits)
    }

    /// Type, frame count, each frame's sides, and the pixels of all frames
    /// together: an image decodes to at most `imagePixels`, however it is split.
    private static func validImage(_ source: CGImageSource, type: String, limits: ClipboardLimits) -> Bool {
        guard let actual = CGImageSourceGetType(source) as String?,
              UTType(actual)?.conforms(to: UTType(type) ?? .data) == true else { return false }
        let frames = CGImageSourceGetCount(source)
        guard frames >= 1, frames <= limits.imageFrames else { return false }
        var pixels = 0
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, headerOnly) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= limits.imageDimension, height <= limits.imageDimension else { return false }
            pixels += width * height                        // ≤ 64 frames of ≤ 2^28 px each: no overflow
            guard pixels <= limits.imagePixels else { return false }
        }
        return true
    }
}
