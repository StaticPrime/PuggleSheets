import Foundation

/// Turns the bytes of a text file into a string, detecting the encoding as spreadsheet apps do:
/// a byte order mark wins; otherwise valid UTF-8 is UTF-8 and anything else is Windows-1252.
enum DelimitedTextDecoding {
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return utf16(bytes[2...], littleEndian: true)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return utf16(bytes[2...], littleEndian: false)
        }
        if let text = String(bytes: bytes, encoding: .utf8) {
            return text
        }
        return windows1252(bytes)
    }

    /// UTF-16 code units; unpaired surrogates become U+FFFD and an odd trailing byte is dropped.
    private static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(littleEndian ? first | second << 8 : first << 8 | second)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Windows-1252: Latin-1 except for 0x80–0x9F, where it has typographic characters. The five bytes
    /// it leaves undefined map to the matching C1 control characters, as Windows does.
    static func windows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            let value = (0x80...0x9F).contains(byte) ? windows1252Specials[Int(byte) - 0x80] : UInt32(byte)
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    private static let windows1252Specials: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]
}
