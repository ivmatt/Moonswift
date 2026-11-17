import CoreMedia
import Foundation

/// What VideoToolbox needs to decode an AV1 stream, read from the sequence header OBU at the start of each keyframe.
/// H.264 and HEVC have Core Media helpers for this (from SPS/PPS); AV1 doesn't, so moonlight-ios uses FFmpeg. This
/// reads the few fields it needs by hand (AV1 spec section 5.5) and builds the "av1C" box (AV1-ISOBMFF section 2.3).
nonisolated struct AV1SequenceHeader: Equatable {
    var profile = 0, level = 0, tier = 0
    var bitDepth = 8, monochrome = false
    var subsamplingX = true, subsamplingY = true, chromaSamplePosition = 0
    var colorPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2 // 2: unspecified
    var fullRange = false
    var width = 0, height = 0
    /// The whole OBU (header, size, payload), which av1C carries as its configuration OBU.
    var obu = Data()

    /// The sequence header in a temporal unit (one frame's OBUs), or nil if there's none or it can't be read.
    static func find(in data: Data) -> AV1SequenceHeader? {
        let bytes = [UInt8](data)
        var position = 0
        while position < bytes.count {
            let header = bytes[position]
            let type = Int(header >> 3) & 0xF
            let headerLength = header & 0x04 != 0 ? 2 : 1 // the extension byte
            var payloadStart = position + headerLength
            let size: Int
            if header & 0x02 != 0 { // obu_has_size_field
                guard let (value, length) = leb128(bytes, at: payloadStart) else { return nil }
                size = value
                payloadStart += length
            } else {
                size = bytes.count - payloadStart // the last OBU may run to the end
            }
            guard size >= 0 else { return nil } // a header cut off before its extension byte
            guard payloadStart + size <= bytes.count else { return nil }
            if type == 1 { // OBU_SEQUENCE_HEADER
                let payload = Array(bytes[payloadStart..<payloadStart + size])
                guard var parsed = parse(payload) else { return nil }
                // av1C wants the OBU with a size field; add one if the stream left it out.
                parsed.obu = header & 0x02 != 0 ? Data(bytes[position..<payloadStart + size])
                    : Data([header | 0x02]) + bytes[(position + 1)..<(position + headerLength)] + leb128Bytes(size) + payload
                return parsed
            }
            position = payloadStart + size
        }
        return nil
    }

    /// The av1C box contents: marker and version, profile and level, the colour format bits, then the OBU.
    var codecConfiguration: Data {
        var box = Data([0x81, UInt8(profile << 5 | level)])
        box.append(UInt8(tier << 7) | (bitDepth > 8 ? 0x40 : 0) | (bitDepth == 12 ? 0x20 : 0) | (monochrome ? 0x10 : 0)
                   | (subsamplingX ? 0x08 : 0) | (subsamplingY ? 0x04 : 0) | UInt8(chromaSamplePosition & 3))
        box.append(0) // no initial presentation delay
        return box + obu
    }

    /// The format description's extensions, as moonlight-ios sets them, plus any HDR metadata.
    func formatExtensions(adding extra: [CFString: Data] = [:]) -> [CFString: Any] {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_FormatName: "av01",
            kCMFormatDescriptionExtension_Depth: 24, // YUV without alpha
            kCMFormatDescriptionExtension_FullRangeVideo: fullRange,
            kCMFormatDescriptionExtension_FieldCount: 1, // progressive
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": codecConfiguration] as CFDictionary,
            "BitsPerComponent" as CFString: bitDepth,
        ]
        let primaries: [Int: CFString] = [1: kCMFormatDescriptionColorPrimaries_ITU_R_709_2, 6: kCMFormatDescriptionColorPrimaries_SMPTE_C,
                                          9: kCMFormatDescriptionColorPrimaries_ITU_R_2020]
        let transfers: [Int: CFString] = [1: kCMFormatDescriptionTransferFunction_ITU_R_709_2, 6: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                                          7: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995, 8: kCMFormatDescriptionTransferFunction_Linear,
                                          14: kCMFormatDescriptionTransferFunction_ITU_R_2020, 15: kCMFormatDescriptionTransferFunction_ITU_R_2020,
                                          16: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, 17: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG]
        let matrices: [Int: CFString] = [1: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, 6: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
                                         7: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995, 9: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020]
        extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries[colorPrimaries]
        extensions[kCMFormatDescriptionExtension_TransferFunction] = transfers[transferCharacteristics]
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrices[matrixCoefficients]
        extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = [1: kCMFormatDescriptionChromaLocation_Left,
                                                                           2: kCMFormatDescriptionChromaLocation_TopLeft][chromaSamplePosition]
        for (key, value) in extra { extensions[key] = value }
        return extensions
    }

    func formatDescription(adding extra: [CFString: Data] = [:]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: Int32(width),
                                                    height: Int32(height), extensions: formatExtensions(adding: extra) as CFDictionary,
                                                    formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    // MARK: Reading

    /// sequence_header_obu(): every field up to color_config, most of them only skipped over.
    private static func parse(_ payload: [UInt8]) -> AV1SequenceHeader? {
        var bits = BitReader(payload)
        var header = AV1SequenceHeader()
        header.profile = bits.read(3)
        bits.skip(1) // still_picture
        let reducedStillPicture = bits.flag()
        if reducedStillPicture {
            header.level = bits.read(5)
        } else {
            var decoderModelInfoPresent = false
            var bufferDelayLength = 0
            if bits.flag() { // timing_info_present_flag
                bits.skip(64) // num_units_in_display_tick, time_scale
                if bits.flag() { bits.skipUVLC() } // equal_picture_interval: num_ticks_per_picture_minus_1
                decoderModelInfoPresent = bits.flag()
                if decoderModelInfoPresent {
                    bufferDelayLength = bits.read(5) + 1
                    bits.skip(32 + 5 + 5) // num_units_in_decoding_tick, two length fields
                }
            }
            let initialDisplayDelayPresent = bits.flag()
            let operatingPoints = bits.read(5) + 1
            for index in 0..<operatingPoints {
                bits.skip(12) // operating_point_idc
                let level = bits.read(5)
                let tier = level > 7 ? bits.read(1) : 0
                if index == 0 { (header.level, header.tier) = (level, tier) }
                if decoderModelInfoPresent, bits.flag() { bits.skip(2 * bufferDelayLength + 1) } // operating_parameters_info
                if initialDisplayDelayPresent, bits.flag() { bits.skip(4) }
            }
        }
        let widthBits = bits.read(4) + 1, heightBits = bits.read(4) + 1
        header.width = bits.read(widthBits) + 1
        header.height = bits.read(heightBits) + 1
        if !reducedStillPicture, bits.flag() { bits.skip(4 + 3) } // frame_id_numbers_present_flag: their lengths
        bits.skip(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
        if !reducedStillPicture {
            bits.skip(4) // interintra compound, masked compound, warped motion, dual filter
            let orderHint = bits.flag()
            if orderHint { bits.skip(2) } // enable_jnt_comp, enable_ref_frame_mvs
            let forceScreenContentTools = bits.flag() ? 2 : bits.read(1) // seq_choose_screen_content_tools
            if forceScreenContentTools > 0, !bits.flag() { bits.skip(1) } // seq_choose_integer_mv, else seq_force_integer_mv
            if orderHint { bits.skip(3) } // order_hint_bits_minus_1
        }
        bits.skip(3) // enable_superres, enable_cdef, enable_restoration

        // color_config()
        let highBitDepth = bits.flag()
        header.bitDepth = header.profile == 2 && highBitDepth ? (bits.flag() ? 12 : 10) : (highBitDepth ? 10 : 8)
        header.monochrome = header.profile == 1 ? false : bits.flag()
        if bits.flag() { // color_description_present_flag
            header.colorPrimaries = bits.read(8)
            header.transferCharacteristics = bits.read(8)
            header.matrixCoefficients = bits.read(8)
        }
        if header.monochrome {
            header.fullRange = bits.flag()
        } else if header.colorPrimaries == 1, header.transferCharacteristics == 13, header.matrixCoefficients == 0 {
            (header.fullRange, header.subsamplingX, header.subsamplingY) = (true, false, false) // sRGB 4:4:4
        } else {
            header.fullRange = bits.flag()
            switch header.profile {
            case 0: (header.subsamplingX, header.subsamplingY) = (true, true)
            case 1: (header.subsamplingX, header.subsamplingY) = (false, false)
            default:
                if header.bitDepth == 12 {
                    header.subsamplingX = bits.flag()
                    header.subsamplingY = header.subsamplingX ? bits.flag() : false
                } else {
                    (header.subsamplingX, header.subsamplingY) = (true, false)
                }
            }
            if header.subsamplingX, header.subsamplingY { header.chromaSamplePosition = bits.read(2) }
        }
        return bits.isPastEnd ? nil : header
    }

    private static func leb128(_ bytes: [UInt8], at start: Int) -> (value: Int, length: Int)? {
        var value = 0
        for index in 0..<8 where start + index < bytes.count {
            let byte = bytes[start + index]
            value |= Int(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return (value, index + 1) }
        }
        return nil
    }

    private static func leb128Bytes(_ value: Int) -> Data {
        var value = value, bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }
}

/// Reads big-endian bit fields, AV1's f(n). Reading past the end gives zeros and sets `isPastEnd`.
nonisolated private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0 // in bits
    private(set) var isPastEnd = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position / 8
            if byte >= bytes.count { isPastEnd = true }
            let bit = byte < bytes.count ? Int(bytes[byte] >> (7 - position % 8)) & 1 : 0
            value = value << 1 | bit
            position += 1
        }
        return value
    }

    mutating func flag() -> Bool { read(1) == 1 }
    mutating func skip(_ count: Int) { position += count; if position > bytes.count * 8 { isPastEnd = true } }

    /// uvlc(): leading zeros, a one, then that many bits.
    mutating func skipUVLC() {
        var zeros = 0
        while !isPastEnd, !flag() { zeros += 1 }
        if zeros < 32 { skip(zeros) }
    }
}
