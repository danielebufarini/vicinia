// Vicinia — HEVC bitstream helpers (NAL types, RBSP, SPS geometry).
// SPDX-License-Identifier: MIT
//
// NAL-type constants and the IRAP range; SPS syntax per ITU-T H.265 §7.3.2.2.

import Foundation

enum HEVCNAL {
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let aggregation: UInt8 = 48
    static let fragmentation: UInt8 = 49

    static func type(_ firstByte: UInt8) -> UInt8 { (firstByte >> 1) & 0x3F }
    static func isVCL(_ type: UInt8) -> Bool { type < 32 }
    /// BLA_W_LP (16) … CRA_NUT (21): random-access pictures.
    static func isIRAP(_ type: UInt8) -> Bool { (16...21).contains(type) }
    static func isParameterSet(_ type: UInt8) -> Bool { (32...34).contains(type) }
}

enum BitstreamError: Error, Equatable {
    case truncated
    case invalid(String)
}

/// Removes emulation-prevention bytes (00 00 03 → 00 00).
func hevcRBSP<C: Collection>(_ ebsp: C) -> [UInt8] where C.Element == UInt8 {
    var out = [UInt8]()
    out.reserveCapacity(ebsp.count)
    var zeros = 0
    for byte in ebsp {
        if zeros >= 2 && byte == 0x03 {
            zeros = 0
            continue
        }
        out.append(byte)
        zeros = byte == 0 ? zeros + 1 : 0
    }
    return out
}

struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u(_ n: Int) throws -> UInt64 {
        precondition(n >= 0 && n <= 64)
        guard bit + n <= bytes.count * 8 else { throw BitstreamError.truncated }
        var value: UInt64 = 0
        for _ in 0..<n {
            let b = (bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1
            value = (value << 1) | UInt64(b)
            bit += 1
        }
        return value
    }

    mutating func flag() throws -> Bool { try u(1) == 1 }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, bit + n <= bytes.count * 8 else { throw BitstreamError.truncated }
        bit += n
    }

    /// Exp-Golomb ue(v), bounded to 32 leading zeros.
    mutating func ue() throws -> UInt64 {
        var zeros = 0
        while try u(1) == 0 {
            zeros += 1
            guard zeros <= 32 else { throw BitstreamError.invalid("ue(v) too long") }
        }
        return (UInt64(1) << UInt64(zeros)) - 1 + (try u(zeros))
    }
}

/// The subset of an HEVC SPS needed to describe decoded geometry.
struct HEVCSequenceParameters: Equatable, Sendable {
    var profileIDC: Int
    var levelIDC: Int
    var chromaFormatIDC: Int          // 3 = 4:4:4
    var bitDepthLuma: Int
    var bitDepthChroma: Int
    var codedWidth: Int               // pic_width_in_luma_samples
    var codedHeight: Int              // pic_height_in_luma_samples
    var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0   // luma samples
    var maxDecPicBuffering: Int?
    var maxNumReorderPics: Int?

    var visibleWidth: Int { codedWidth - cropLeft - cropRight }
    var visibleHeight: Int { codedHeight - cropTop - cropBottom }
    var hasConformanceWindow: Bool { cropLeft + cropRight + cropTop + cropBottom > 0 }

    var summary: String {
        "profile=\(profileIDC) level=\(levelIDC) chroma_format_idc=\(chromaFormatIDC) "
            + "bitdepth=\(bitDepthLuma)/\(bitDepthChroma) coded=\(codedWidth)x\(codedHeight) "
            + "crop(l,r,t,b)=(\(cropLeft),\(cropRight),\(cropTop),\(cropBottom)) "
            + "visible=\(visibleWidth)x\(visibleHeight) "
            + "max_dec_pic_buffering=\(maxDecPicBuffering.map(String.init) ?? "?") "
            + "max_num_reorder=\(maxNumReorderPics.map(String.init) ?? "?")"
    }

    /// Parses an SPS NAL unit (including its 2-byte NAL header).
    init(spsNAL nal: Data) throws {
        guard nal.count > 3, HEVCNAL.type(nal[nal.startIndex]) == HEVCNAL.sps else {
            throw BitstreamError.invalid("not an SPS")
        }
        var r = BitReader(hevcRBSP(nal.dropFirst(2)))
        try r.skip(4)                                   // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(try r.u(3))
        try r.skip(1)                                   // temporal_id_nesting
        // profile_tier_level(1, maxSubLayersMinus1)
        try r.skip(2 + 1)                               // profile_space, tier
        profileIDC = Int(try r.u(5))
        try r.skip(32 + 4 + 43 + 1)                     // compat flags, source flags, constraints
        levelIDC = Int(try r.u(8))
        var subProfile = [Bool](), subLevel = [Bool]()
        for _ in 0..<maxSubLayersMinus1 {
            subProfile.append(try r.flag())
            subLevel.append(try r.flag())
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { try r.skip(2) }
        }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { try r.skip(88) }
            if subLevel[i] { try r.skip(8) }
        }
        _ = try r.ue()                                  // sps_seq_parameter_set_id
        chromaFormatIDC = Int(try r.ue())
        guard chromaFormatIDC <= 3 else { throw BitstreamError.invalid("chroma_format_idc") }
        if chromaFormatIDC == 3 { try r.skip(1) }       // separate_colour_plane_flag
        codedWidth = Int(try r.ue())
        codedHeight = Int(try r.ue())
        guard (1...16384).contains(codedWidth), (1...16384).contains(codedHeight) else {
            throw BitstreamError.invalid("picture size")
        }
        let subW = chromaFormatIDC == 1 || chromaFormatIDC == 2 ? 2 : 1
        let subH = chromaFormatIDC == 1 ? 2 : 1
        if try r.flag() {                               // conformance_window_flag
            cropLeft = Int(try r.ue()) * subW
            cropRight = Int(try r.ue()) * subW
            cropTop = Int(try r.ue()) * subH
            cropBottom = Int(try r.ue()) * subH
            guard cropLeft + cropRight < codedWidth, cropTop + cropBottom < codedHeight else {
                throw BitstreamError.invalid("conformance window")
            }
        }
        bitDepthLuma = Int(try r.ue()) + 8
        bitDepthChroma = Int(try r.ue()) + 8
        _ = try r.ue()                                  // log2_max_pic_order_cnt_lsb_minus4
        let orderingInfoAll = try r.flag()
        for _ in (orderingInfoAll ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            maxDecPicBuffering = Int(try r.ue()) + 1
            maxNumReorderPics = Int(try r.ue())
            _ = try r.ue()                              // max_latency_increase_plus1
        }
    }
}
