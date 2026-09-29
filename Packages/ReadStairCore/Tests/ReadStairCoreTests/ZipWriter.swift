import Foundation
@testable import ReadStairCore

/// Writes ZIP archives in memory for the ZIP and EPUB tests. Each entry is written as given, with its real CRC-32 and size unless a
/// test declares others to make a broken archive.
struct ZipWriter {
    struct Entry {
        var path: String
        /// The bytes as stored: the contents themselves (method 0), or a raw DEFLATE stream (method 8).
        var data: Data
        var flags = 0
        var method = 0
        /// The declared CRC-32 and uncompressed size; nil for those of `data`.
        var crc: UInt32?
        var size: Int?
    }

    var entries: [Entry] = []
    var comment = ""

    /// Adds a stored entry.
    mutating func add(_ path: String, _ text: String) {
        entries.append(Entry(path: path, data: Data(text.utf8)))
    }

    /// Adds a stored entry of bytes, such as an image.
    mutating func add(_ path: String, data: Data) {
        entries.append(Entry(path: path, data: data))
    }

    var archive: Data {
        func le(_ value: Int, _ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
        var archive = Data(), directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            // Flags, method, time and date, CRC-32, sizes, name and extra field lengths: the same in both headers
            let fields = le(entry.flags, 2) + le(entry.method, 2) + le(0, 4) + le(Int(entry.crc ?? ZipArchive.crc32(entry.data)), 4)
                + le(entry.data.count, 4) + le(entry.size ?? entry.data.count, 4) + le(name.count, 2) + le(0, 2)
            // Versions; then comment length, disk number and file attributes, all zero; then the local header's offset
            directory += le(0x0201_4B50, 4) + le(20, 2) + le(20, 2) + fields + le(0, 10) + le(archive.count, 4) + name
            archive += le(0x0403_4B50, 4) + le(20, 2) + fields + name + entry.data
        }
        let comment = Data(comment.utf8)
        return archive + directory + le(0x0605_4B50, 4) + le(0, 4) + le(entries.count, 2) + le(entries.count, 2)
            + le(directory.count, 4) + le(archive.count, 4) + le(comment.count, 2) + comment
    }
}
