import Compression
import Foundation

/// A ZIP archive in memory, read as far as EPUB needs: stored and DEFLATE entries, each checked against its CRC-32. Sizes and
/// offsets come from the central directory, so an entry written with a data descriptor reads the same. ZIP64, split archives and
/// other compression methods are refused as unreadable, an encrypted entry as copy protection.
struct ZipArchive {
    /// The most one entry may hold uncompressed: far more than any chapter, and a bound on what a crafted archive can make us inflate.
    static let maxEntryBytes = 32 << 20

    private struct Entry {
        var flags, method, crc, compressedSize, size, offset: Int
    }

    private let data: Data
    private let entries: [String: Entry]
    /// Every entry's path, in central directory order.
    let paths: [String]

    init(_ data: Data) throws(EBookError) {
        // The end of central directory record is 22 bytes plus a comment of at most 65,535, so it starts in the last 65,557 bytes
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
                  .first(where: { data.int($0, 4) == 0x0605_4B50 }),
              data.int(end + 4, 2) == 0, data.int(end + 6, 2) == 0,
              let count = data.int(end + 10, 2), count != 0xFFFF,
              var position = data.int(end + 16, 4), position != 0xFFFF_FFFF else { throw .unreadable }
        var entries: [String: Entry] = [:]
        var paths: [String] = []
        for _ in 0..<count {
            guard data.int(position, 4) == 0x0201_4B50,
                  let flags = data.int(position + 8, 2), let method = data.int(position + 10, 2), let crc = data.int(position + 16, 4),
                  let compressedSize = data.int(position + 20, 4), let size = data.int(position + 24, 4),
                  let nameLength = data.int(position + 28, 2), let extraLength = data.int(position + 30, 2),
                  let commentLength = data.int(position + 32, 2), let offset = data.int(position + 42, 4),
                  position + 46 + nameLength <= data.count else { throw .unreadable }
            let nameStart = data.startIndex + position + 46
            let path = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)
            if entries[path] == nil {
                entries[path] = Entry(flags: flags, method: method, crc: crc, compressedSize: compressedSize, size: size, offset: offset)
                paths.append(path)
            }
            position += 46 + nameLength + extraLength + commentLength
        }
        self.data = data
        self.entries = entries
        self.paths = paths
    }

    /// The entry's contents, or nil if the archive has no entry at `path`.
    func data(at path: String) throws(EBookError) -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.flags & 1 == 0 else { throw .drm }
        guard ![entry.compressedSize, entry.size, entry.offset].contains(0xFFFF_FFFF), [0, 8].contains(entry.method) else {
            throw .unreadable
        }
        guard entry.size <= Self.maxEntryBytes else { throw .tooLarge }
        // The contents follow the local header: 30 bytes, then its own copies of the name and the extra field
        guard data.int(entry.offset, 4) == 0x0403_4B50, let nameLength = data.int(entry.offset + 26, 2),
              let extraLength = data.int(entry.offset + 28, 2) else { throw .unreadable }
        let start = data.startIndex + entry.offset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.endIndex else { throw .unreadable }
        let stored = data[start..<start + entry.compressedSize]
        let contents = entry.method == 0 ? Data(stored) : Self.inflate(stored, size: entry.size)
        guard let contents, contents.count == entry.size, Self.crc32(contents) == entry.crc else { throw .unreadable }
        return contents
    }

    /// Raw DEFLATE (Compression's COMPRESSION_ZLIB) into exactly `size` bytes, or nil. One byte of room to spare shows a stream that
    /// inflates to more than the directory says.
    private static func inflate(_ compressed: Data, size: Int) -> Data? {
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { out in
            compressed.withUnsafeBytes { input in
                guard let source = input.baseAddress, let destination = out.baseAddress else { return 0 }
                return compression_decode_buffer(destination.assumingMemoryBound(to: UInt8.self), out.count,
                                                 source.assumingMemoryBound(to: UInt8.self), input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        output.count = size
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ crc >> 1 : crc >> 1 }
    }

    /// CRC-32 as ZIP uses it (polynomial 0x04C11DB7, reflected; "123456789" gives 0xCBF43926).
    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ crc >> 8
        }
        return ~crc
    }
}

private extension Data {
    /// The little-endian unsigned integer of `size` bytes at `offset` from the start, or nil if it does not fit in the data.
    func int(_ offset: Int, _ size: Int) -> Int? {
        guard offset >= 0, offset + size <= count else { return nil }
        return (0..<size).reversed().reduce(0) { $0 << 8 | Int(self[startIndex + offset + $1]) }
    }
}
