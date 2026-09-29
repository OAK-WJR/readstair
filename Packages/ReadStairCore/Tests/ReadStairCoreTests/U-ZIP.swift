import Compression
import Foundation
import Testing
@testable import ReadStairCore

/// U-ZIP-001–004: the ZIP reader under EPUB import: CRC-32, stored and DEFLATE entries, and the archives and entries it refuses.
/// Info-ZIP's DEFLATE is read in U-EPUB-001 (Fixtures/alice-chapter-1.epub).
@Suite("U-ZIP ZipArchive")
struct ZipArchiveTests {
    private let text = Data(String(repeating: "Down, down, down. Would the fall never come to an end! ", count: 40).utf8)

    /// A raw DEFLATE stream of `data`, from Compression's encoder.
    private func deflate(_ data: Data) throws -> Data {
        var output = Data(count: data.count + 64)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count,
                                          input.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count, nil, COMPRESSION_ZLIB)
            }
        }
        try #require(written > 0)
        return output.prefix(written)
    }

    /// Writes an archive holding only `entry` and reads the entry back.
    private func read(_ entry: ZipWriter.Entry) throws(EBookError) -> Data? {
        try ZipArchive(ZipWriter(entries: [entry]).archive).data(at: entry.path)
    }

    @Test("U-ZIP-001 CRC-32 check values: \"123456789\" → 0xCBF43926, no bytes → 0")
    func checksum() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test("U-ZIP-002 A stored and a DEFLATE entry read back byte for byte, found after a trailing archive comment; a path not in the archive → nil")
    func roundTrip() throws {
        var zip = ZipWriter(comment: "Written by the U-ZIP tests")
        zip.add("mimetype", "application/epub+zip")
        let deflated = try deflate(text)
        zip.entries.append(.init(path: "OEBPS/chapter.xhtml", data: deflated, method: 8, crc: ZipArchive.crc32(text), size: text.count))
        let archive = try ZipArchive(zip.archive)
        #expect(archive.paths == ["mimetype", "OEBPS/chapter.xhtml"])
        #expect(try archive.data(at: "mimetype") == Data("application/epub+zip".utf8))
        #expect(try archive.data(at: "OEBPS/chapter.xhtml") == text)
        #expect(try archive.data(at: "OEBPS/missing.xhtml") == nil)
    }

    @Test("U-ZIP-003 Not a ZIP archive, its end record cut off, its start cut off (offsets point at the wrong bytes), a split archive, or a ZIP64 entry count or directory offset → unreadable; so is an entry whose local header has the wrong signature")
    func refusedArchives() throws {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip")
        let archive = zip.archive
        /// The archive with `bytes` written at `offset`, counted from the end if negative.
        func patched(_ bytes: [UInt8], at offset: Int) -> Data {
            var data = archive
            let start = offset < 0 ? data.count + offset : offset
            data.replaceSubrange(start..<start + bytes.count, with: bytes)
            return data
        }
        // The end record, with no comment, is the last 22 bytes: disk number at 4, entry count at 10, directory offset at 16
        for data in [Data(), Data("Alice was beginning to get very tired".utf8), archive.dropLast(), archive.dropFirst(4),
                     patched([1, 0], at: -18), patched([0xFF, 0xFF], at: -12), patched([0xFF, 0xFF, 0xFF, 0xFF], at: -6)] {
            #expect(throws: EBookError.unreadable) { try ZipArchive(Data(data)) }
        }
        let wrongSignature = try ZipArchive(patched(Array("PK\u{7}\u{8}".utf8), at: 0))
        #expect(throws: EBookError.unreadable) { try wrongSignature.data(at: "mimetype") }
    }

    @Test("U-ZIP-004 Refused entries: encrypted → drm; a ZIP64 size, method 12, a bad CRC, a wrong stored size, a cut or garbage DEFLATE stream → unreadable; over 32 MB → tooLarge; the data descriptor flag reads")
    func refusedEntries() throws {
        let deflated = try deflate(text)
        let path = "OEBPS/chapter.xhtml"
        #expect(throws: EBookError.drm) { try read(.init(path: path, data: text, flags: 1)) }
        #expect(throws: EBookError.unreadable) { try read(.init(path: path, data: text, size: 0xFFFF_FFFF)) }
        #expect(throws: EBookError.unreadable) { try read(.init(path: path, data: text, method: 12)) }
        #expect(throws: EBookError.unreadable) { try read(.init(path: path, data: text, crc: ZipArchive.crc32(text) ^ 1)) }
        #expect(throws: EBookError.unreadable) { try read(.init(path: path, data: text, size: text.count + 1)) }
        #expect(throws: EBookError.unreadable) {
            try read(.init(path: path, data: deflated.prefix(deflated.count / 2), method: 8, crc: ZipArchive.crc32(text), size: text.count))
        }
        #expect(throws: EBookError.unreadable) {
            try read(.init(path: path, data: Data(repeating: 0xFF, count: 64), method: 8, crc: ZipArchive.crc32(text), size: text.count))
        }
        // A stream that inflates to more than the declared size
        #expect(throws: EBookError.unreadable) { try read(.init(path: path, data: deflated, method: 8, size: text.count - 1)) }
        #expect(throws: EBookError.tooLarge) { try read(.init(path: path, data: deflated, method: 8, size: ZipArchive.maxEntryBytes + 1)) }
        #expect(try read(.init(path: path, data: deflated, method: 8, crc: ZipArchive.crc32(text), size: text.count)) == text)
        // Flag bit 3 (sizes in a data descriptor after the contents) is fine: the sizes are read from the central directory
        #expect(try read(.init(path: path, data: text, flags: 8)) == text)
    }
}
