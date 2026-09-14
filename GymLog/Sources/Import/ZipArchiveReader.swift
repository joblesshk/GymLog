import Foundation
import Compression

/// M7 §3.1: a minimal, read-only ZIP central-directory reader. This is
/// deliberately NOT a general-purpose ZIP library -- it only supports what
/// an `.xlsx` container actually needs: a handful of known, uncompressed-
/// or DEFLATE-compressed XML entries, no encryption, no spanning, no
/// ZIP64. Anything outside that throws a typed error rather than guessing.
///
/// The hard part (inflating DEFLATE-compressed entries) is not hand-rolled:
/// `Compression`'s `COMPRESSION_ZLIB` algorithm is, despite the name, raw
/// DEFLATE with no zlib/gzip framing -- exactly what ZIP "method 8" stores.
/// This reader only has to walk the fixed-width ZIP record layout from
/// APPNOTE.TXT (EOCD -> central directory entries -> local file headers).
public final class ZipArchiveReader: ArchiveReading {
    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let crc32: UInt32
    }

    private let data: Data
    private let entries: [Entry]
    private let entriesByName: [String: Entry]
    /// Running total of bytes actually inflated by `data(forEntry:)` across
    /// this reader's lifetime -- see that method for why this must be
    /// checked before, not after, each allocation (2026-09-07 审阅 B10).
    private var totalDecompressedBytes = 0

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50

    /// A real `.xlsx` this app has ever seen is ~65KB with a handful of
    /// entries (M7 §7 step 10). These are generous multiples of that, not
    /// tight bounds -- they exist to reject a maliciously/accidentally
    /// crafted archive that declares far more central-directory entries or
    /// far more uncompressed bytes than any legitimate spreadsheet could
    /// need, BEFORE this reader allocates memory for them, not after.
    private static let maxCentralDirectoryEntries = 10_000
    private static let maxSingleEntryUncompressedSize = 100_000_000
    private static let maxTotalUncompressedSizeAcrossArchive = 200_000_000

    public init(data: Data) throws {
        self.data = data
        let eocd = try Self.findEndOfCentralDirectory(in: data)
        guard eocd.totalEntries <= Self.maxCentralDirectoryEntries else {
            throw ArchiveReadingError.unsupportedArchive(reason: "central directory declares \(eocd.totalEntries) entries, over the \(Self.maxCentralDirectoryEntries) supported limit")
        }
        self.entries = try Self.readCentralDirectory(
            in: data,
            offset: eocd.centralDirectoryOffset,
            totalEntries: eocd.totalEntries
        )
        var byName: [String: Entry] = [:]
        for entry in entries { byName[entry.name] = entry }
        self.entriesByName = byName
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func entryNames() -> [String] {
        entries.map(\.name)
    }

    public func data(forEntry name: String) throws -> Data {
        guard let entry = entriesByName[name] else {
            throw ArchiveReadingError.entryNotFound(name: name)
        }
        // 2026-09-07 审阅 B10 (代码确认): both checks below happen BEFORE
        // `Self.inflate` allocates its `expectedSize`-byte destination
        // buffer -- a small compressed file can still declare an
        // arbitrarily large `uncompressedSize` in its central directory
        // (up to ~4GB per entry, and unbounded in aggregate across many
        // small entries), and the old code allocated straight from that
        // declared field with no upper bound at all.
        guard entry.uncompressedSize <= Self.maxSingleEntryUncompressedSize else {
            throw ArchiveReadingError.unsupportedArchive(reason: "entry \"\(name)\" declares \(entry.uncompressedSize) uncompressed bytes, over the \(Self.maxSingleEntryUncompressedSize)-byte per-entry limit")
        }
        guard totalDecompressedBytes + entry.uncompressedSize <= Self.maxTotalUncompressedSizeAcrossArchive else {
            throw ArchiveReadingError.unsupportedArchive(reason: "reading entry \"\(name)\" would exceed the \(Self.maxTotalUncompressedSizeAcrossArchive)-byte total decompression budget for this archive")
        }
        let payload = try Self.localFileData(in: data, entry: entry)
        let inflated: Data
        switch entry.compressionMethod {
        case 0:
            guard payload.count == entry.uncompressedSize else {
                throw ArchiveReadingError.corruptEntry(name: name, reason: "stored size mismatch")
            }
            inflated = payload
        case 8:
            inflated = try Self.inflate(payload, expectedSize: entry.uncompressedSize, entryName: name)
        default:
            throw ArchiveReadingError.unsupportedArchive(reason: "entry \"\(name)\" uses unsupported compression method \(entry.compressionMethod)")
        }
        guard Self.crc32(of: inflated) == entry.crc32 else {
            throw ArchiveReadingError.corruptEntry(name: name, reason: "CRC-32 mismatch after decompression")
        }
        totalDecompressedBytes += inflated.count
        return inflated
    }

    // MARK: - End of Central Directory

    private struct EOCD {
        let totalEntries: Int
        let centralDirectoryOffset: Int
    }

    /// The EOCD is a fixed 22-byte record, but it can be followed by up to
    /// 65535 bytes of archive comment, so it isn't simply "the last 22
    /// bytes" -- scan backward for the signature, bounded to the maximum
    /// possible comment length so a huge file doesn't force a full scan.
    private static func findEndOfCentralDirectory(in data: Data) throws -> EOCD {
        let minEOCDSize = 22
        guard data.count >= minEOCDSize else { throw ArchiveReadingError.notAnArchive }
        let maxCommentLength = 65535
        let searchStart = max(0, data.count - minEOCDSize - maxCommentLength)
        var offset = data.count - minEOCDSize
        while offset >= searchStart {
            if readUInt32LE(data, at: offset) == endOfCentralDirectorySignature {
                let totalEntries = Int(readUInt16LE(data, at: offset + 10))
                let centralDirSize = readUInt32LE(data, at: offset + 12)
                let centralDirOffset = readUInt32LE(data, at: offset + 16)
                if totalEntries == 0xFFFF || centralDirOffset == 0xFFFF_FFFF || centralDirSize == 0xFFFF_FFFF {
                    throw ArchiveReadingError.unsupportedArchive(reason: "ZIP64 archives are not supported")
                }
                return EOCD(totalEntries: totalEntries, centralDirectoryOffset: Int(centralDirOffset))
            }
            offset -= 1
        }
        throw ArchiveReadingError.notAnArchive
    }

    // MARK: - Central directory

    private static func readCentralDirectory(in data: Data, offset startOffset: Int, totalEntries: Int) throws -> [Entry] {
        var offset = startOffset
        var results: [Entry] = []
        results.reserveCapacity(totalEntries)
        for _ in 0..<totalEntries {
            guard offset + 46 <= data.count, readUInt32LE(data, at: offset) == centralDirectoryHeaderSignature else {
                throw ArchiveReadingError.unsupportedArchive(reason: "central directory entry has a bad signature")
            }
            let compressionMethod = readUInt16LE(data, at: offset + 10)
            let crc32Value = readUInt32LE(data, at: offset + 16)
            let compressedSize = readUInt32LE(data, at: offset + 20)
            let uncompressedSize = readUInt32LE(data, at: offset + 24)
            let fileNameLength = Int(readUInt16LE(data, at: offset + 28))
            let extraFieldLength = Int(readUInt16LE(data, at: offset + 30))
            let fileCommentLength = Int(readUInt16LE(data, at: offset + 32))
            let localHeaderOffset = readUInt32LE(data, at: offset + 42)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw ArchiveReadingError.unsupportedArchive(reason: "ZIP64 entries are not supported")
            }

            let nameStart = offset + 46
            guard nameStart + fileNameLength <= data.count else {
                throw ArchiveReadingError.unsupportedArchive(reason: "central directory entry name runs past end of file")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + fileNameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ArchiveReadingError.unsupportedArchive(reason: "central directory entry name isn't valid UTF-8")
            }

            results.append(Entry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset),
                crc32: crc32Value
            ))

            offset = nameStart + fileNameLength + extraFieldLength + fileCommentLength
        }
        return results
    }

    // MARK: - Local file header + payload

    private static func localFileData(in data: Data, entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count, readUInt32LE(data, at: offset) == localFileHeaderSignature else {
            throw ArchiveReadingError.corruptEntry(name: entry.name, reason: "local file header has a bad signature")
        }
        let fileNameLength = Int(readUInt16LE(data, at: offset + 26))
        let extraFieldLength = Int(readUInt16LE(data, at: offset + 28))
        let payloadStart = offset + 30 + fileNameLength + extraFieldLength
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= data.count else {
            throw ArchiveReadingError.corruptEntry(name: entry.name, reason: "entry data runs past end of file")
        }
        return data.subdata(in: payloadStart..<payloadEnd)
    }

    // MARK: - DEFLATE

    private static func inflate(_ compressed: Data, expectedSize: Int, entryName: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = destination.withUnsafeMutableBufferPointer { destBuffer -> Int in
            compressed.withUnsafeBytes { srcBuffer -> Int in
                guard let destBase = destBuffer.baseAddress,
                      let srcBase = srcBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destBase, expectedSize, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw ArchiveReadingError.corruptEntry(name: entryName, reason: "DEFLATE decompression produced \(written) bytes, expected \(expectedSize)")
        }
        return Data(destination)
    }

    // MARK: - Little-endian reads

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    // MARK: - CRC-32 (standard zlib/ZIP polynomial, table-based)

    private static let crc32Table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crc32Table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
