import Foundation
import Testing
@testable import PuggleSheetsKit

struct IOZipTests {
    @Test func crc32MatchesKnownValues() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        // Every length around the eight-byte fast path agrees with the byte-at-a-time definition.
        var random = IOTestRandom(seed: 7)
        let bytes = random.bytes(40)
        for length in 0...bytes.count {
            let slice = bytes.prefix(length)
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in slice {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
            }
            #expect(CRC32.checksum(Data(slice)) == crc ^ 0xFFFF_FFFF)
        }
    }

    @Test func storedAndDeflatedEntriesRoundTrip() throws {
        let text = Data(String(repeating: "PuggleSheets reads and writes spreadsheets. ", count: 500).utf8)
        var writer = ZipWriter()
        try writer.add("xl/deflated.xml", text)
        try writer.add("xl/stored.xml", text, compress: false)
        try writer.add("empty.txt", Data())
        try writer.add("naïve/ünïcode.txt", Data("é".utf8))
        let archive = try writer.finish()
        #expect(archive.count < text.count + 2000)

        let reader = try ZipReader(data: archive)
        #expect(reader.entries.map(\.path) == ["xl/deflated.xml", "xl/stored.xml", "empty.txt", "naïve/ünïcode.txt"])
        #expect(reader.entry("xl/deflated.xml")?.method == 8)
        #expect(reader.entry("xl/stored.xml")?.method == 0)
        #expect(try reader.read("xl/deflated.xml") == text)
        #expect(try reader.read("xl/stored.xml") == text)
        #expect(try reader.read("empty.txt") == Data())
        #expect(try reader.read("naïve/ünïcode.txt") == Data("é".utf8))
        #expect(try reader.read("missing.xml") == nil)
    }

    @Test func largeEntriesRoundTrip() throws {
        var random = IOTestRandom(seed: 42)
        var large = Data(capacity: 6_000_000)
        for row in 0..<100_000 {
            large.append(contentsOf: "<row r=\"\(row + 1)\"><c><v>\(random.next() % 100_000)</v></c></row>\n".utf8)
        }
        let noise = random.bytes(300_000)
        var writer = ZipWriter()
        try writer.add("large.xml", large)
        try writer.add("noise.bin", noise)
        let archive = try writer.finish()
        #expect(archive.count < large.count / 3 + noise.count + 10_000)
        let reader = try ZipReader(data: archive)
        #expect(try reader.read("large.xml") == large)
        #expect(try reader.read("noise.bin") == noise)
    }

    @Test func incompressibleDataIsStored() throws {
        var random = IOTestRandom(seed: 1)
        let noise = random.bytes(4096)
        var writer = ZipWriter()
        try writer.add("noise.bin", noise)
        let reader = try ZipReader(data: try writer.finish())
        #expect(reader.entry("noise.bin")?.method == 0)
        #expect(try reader.read("noise.bin") == noise)
    }

    @Test func dataDescriptorsUseTheCentralDirectory() throws {
        let text = Data(String(repeating: "streamed ", count: 2000).utf8)
        var writer = ZipWriter()
        try writer.add("deflated.txt", text, dataDescriptor: true)
        try writer.add("stored.txt", text, compress: false, dataDescriptor: true)
        let archive = try writer.finish()
        // The local headers hold no sizes or checksum.
        #expect(archive.withUnsafeBytes { $0.zipUInt32(at: 14) } == 0)
        #expect(archive.withUnsafeBytes { $0.zipUInt32(at: 18) } == 0)
        let reader = try ZipReader(data: archive)
        #expect((reader.entry("deflated.txt")?.flags ?? 0) & 0x08 != 0)
        #expect(try reader.read("deflated.txt") == text)
        #expect(try reader.read("stored.txt") == text)
    }

    @Test func archiveCommentsAndPrefixedNamesAreHandled() throws {
        var writer = ZipWriter()
        try writer.add("/xl\\workbook.xml", Data("<workbook/>".utf8))
        var archive = try writer.finish()
        // An archive comment after the end record.
        let comment = Data("written by a test".utf8)
        archive[archive.count - 2] = UInt8(comment.count)
        archive.append(comment)
        let reader = try ZipReader(data: archive)
        #expect(reader.entries.map(\.path) == ["xl/workbook.xml"])
        #expect(reader.contains("XL/Workbook.XML"))
        #expect(reader.contains("/xl/workbook.xml"))
        #expect(try reader.read("xl/WORKBOOK.xml") == Data("<workbook/>".utf8))
    }

    @Test func rejectsWhatIsNotAZipArchive() {
        #expect(throws: ZipError.notAZip) { try ZipReader(data: Data()) }
        #expect(throws: ZipError.notAZip) { try ZipReader(data: Data("just some text, long enough to look at".utf8)) }
        var random = IOTestRandom(seed: 3)
        #expect(throws: ZipError.notAZip) { try ZipReader(data: random.bytes(10_000)) }
    }

    @Test func detectsDamage() throws {
        let text = Data(String(repeating: "damage ", count: 1000).utf8)
        var writer = ZipWriter()
        try writer.add("a.txt", text)
        try writer.add("b.txt", text, compress: false)
        let archive = try writer.finish()

        // A flipped byte in the stored entry fails its checksum.
        let reader = try ZipReader(data: archive)
        let stored = try #require(reader.entry("b.txt"))
        var corrupted = archive
        corrupted[stored.localHeaderOffset + 30 + 5 + 10] ^= 0xFF
        #expect(throws: ZipError.damaged) { try ZipReader(data: corrupted).read("b.txt") }

        // Damaged compressed data.
        let deflated = try #require(reader.entry("a.txt"))
        var garbled = archive
        for offset in 0..<deflated.compressedSize / 2 { garbled[deflated.localHeaderOffset + 30 + 5 + offset] = 0xFF }
        #expect(throws: ZipError.damaged) { try ZipReader(data: garbled).read("a.txt") }

        // A truncated archive loses its central directory.
        #expect(throws: ZipError.notAZip) { try ZipReader(data: archive.prefix(archive.count / 2)) }
    }

    @Test func sizeLimitStopsZipBombs() throws {
        let zeros = Data(count: 10_000_000)
        var writer = ZipWriter()
        try writer.add("zeros.bin", zeros)
        try writer.add("small.txt", Data("ok".utf8))
        let archive = try writer.finish()
        #expect(archive.count < 100_000)

        let limited = try ZipReader(data: archive, sizeLimit: 1_000_000)
        #expect(try limited.read("small.txt") == Data("ok".utf8))
        #expect(throws: ZipError.tooLarge) { try limited.read("zeros.bin") }

        // Each read counts against the same budget.
        let budget = try ZipReader(data: archive, sizeLimit: 15_000_000)
        #expect(try budget.read("zeros.bin")?.count == 10_000_000)
        #expect(throws: ZipError.tooLarge) { try budget.read("zeros.bin") }
    }

    @Test func lyingSizesAreRefusedWithoutExpanding() throws {
        let zeros = Data(count: 1_000_000)
        var writer = ZipWriter()
        try writer.add("zeros.bin", zeros)
        var archive = try writer.finish()
        // Claim a much smaller uncompressed size in the central directory.
        let directory = try #require(archive.withUnsafeBytes { bytes -> Int? in
            (0..<(bytes.count - 4)).first { bytes.zipUInt32(at: $0) == ZipSignature.centralHeader }
        })
        archive.replaceSubrange((directory + 24)..<(directory + 28), with: [0xE8, 0x03, 0x00, 0x00])
        #expect(throws: ZipError.damaged) { try ZipReader(data: archive).read("zeros.bin") }
    }

    @Test func encryptedEntriesAreUnsupported() throws {
        var writer = ZipWriter()
        try writer.add("secret.txt", Data("secret".utf8), compress: false)
        var archive = try writer.finish()
        let directory = try #require(archive.withUnsafeBytes { bytes -> Int? in
            (0..<(bytes.count - 4)).first { bytes.zipUInt32(at: $0) == ZipSignature.centralHeader }
        })
        archive[directory + 8] |= 1
        #expect(throws: ZipError.unsupported) { try ZipReader(data: archive).read("secret.txt") }
    }
}
