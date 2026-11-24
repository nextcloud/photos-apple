// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation

/// Reads the entries of a ZIP archive one at a time, without unpacking the whole archive (a Google Takeout export is
/// often tens of gigabytes, split into 2–50 GB parts). Stored and deflated entries, ZIP64; no encryption.
public struct ZipReader: Sendable {
    public struct Entry: Hashable, Sendable {
        /// Path inside the archive, with `/` separators.
        public var path: String
        public var compressedSize: UInt64
        public var size: UInt64
        var method: UInt16
        var crc32: UInt32
        var localHeaderOffset: UInt64
        var isEncrypted: Bool

        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public enum ZipError: Error, Equatable, LocalizedError {
        case notAZip
        case truncated
        case unsupportedMethod(UInt16)
        case encrypted
        case checksumMismatch(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip, .truncated: String(localized: "The file is not a complete ZIP archive.", bundle: .module)
            case .unsupportedMethod: String(localized: "The ZIP archive uses a compression this app cannot read.", bundle: .module)
            case .encrypted: String(localized: "The ZIP archive is encrypted.", bundle: .module)
            case .checksumMismatch(let name), .corrupt(let name):
                String(localized: "“\(name)” in the ZIP archive is damaged.", bundle: .module)
            }
        }
    }

    public let url: URL
    public let entries: [Entry]

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        entries = try Self.readCentralDirectory(handle)
    }

    // MARK: Central directory

    static func readCentralDirectory(_ handle: FileHandle) throws -> [Entry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.notAZip }
        // The end record is in the last 64 KiB + 22 bytes (its comment is at most 64 KiB).
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let endIndex = lastSignature(0x0605_4b50, in: tail) else { throw ZipError.notAZip }
        let end = tail[endIndex...]
        guard end.count >= 22 else { throw ZipError.truncated }
        var count = UInt64(end.uint16(at: 10))
        var directorySize = UInt64(end.uint32(at: 12))
        var directoryOffset = UInt64(end.uint32(at: 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: a locator right before the end record points to the ZIP64 end record.
            let locatorIndex = endIndex - 20
            guard locatorIndex >= tail.startIndex, tail.uint32(at: locatorIndex - tail.startIndex) == 0x0706_4b50 else {
                throw ZipError.corrupt("ZIP64")
            }
            let recordOffset = tail.uint64(at: locatorIndex - tail.startIndex + 8)
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.uint32(at: 0) == 0x0606_4b50 else { throw ZipError.corrupt("ZIP64") }
            count = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }
        guard directoryOffset + directorySize <= fileSize else { throw ZipError.truncated }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else { throw ZipError.truncated }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 1_000_000)))
        var position = 0
        while position + 46 <= directory.count, directory.uint32(at: position) == 0x0201_4b50 {
            let flags = directory.uint16(at: position + 8)
            let method = directory.uint16(at: position + 10)
            let crc = directory.uint32(at: position + 16)
            var compressed = UInt64(directory.uint32(at: position + 20))
            var size = UInt64(directory.uint32(at: position + 24))
            let nameLength = Int(directory.uint16(at: position + 28))
            let extraLength = Int(directory.uint16(at: position + 30))
            let commentLength = Int(directory.uint16(at: position + 32))
            var offset = UInt64(directory.uint32(at: position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength <= directory.count else { throw ZipError.truncated }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            // UTF-8 names (flag bit 11, which Takeout sets); older tools wrote code page 437, read here as Latin-1.
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            // ZIP64 extra field: the 8-byte values of the fields that are 0xFFFFFFFF, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.uint16(at: extra)
                let length = Int(directory.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        size = directory.uint64(at: field)
                        field += 8
                    }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        compressed = directory.uint64(at: field)
                        field += 8
                    }
                    if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = directory.uint64(at: field) }
                }
                extra += 4 + length
            }
            entries.append(
                Entry(
                    path: name, compressedSize: compressed, size: size, method: method, crc32: crc, localHeaderOffset: offset,
                    isEncrypted: flags & 0x0001 != 0))
            position = extraEnd + commentLength
        }
        return entries
    }

    static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.endIndex - 4
        while index >= data.startIndex {
            if data.uint32(at: index - data.startIndex) == signature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: Reading entries

    /// The entry's content in memory (sidecars, album metadata). Refuses entries above `limit`.
    public func data(of entry: Entry, limit: UInt64 = 4 << 20) throws -> Data {
        guard entry.size <= limit else { throw ZipError.corrupt(entry.path) }
        var result = Data()
        try stream(entry) { result.append($0) }
        return result
    }

    /// Writes the entry into a new file at `destination`.
    public func extract(_ entry: Entry, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try stream(entry) { try output.write(contentsOf: $0) }
    }

    /// Hands the entry's content to `write` in pieces and checks its CRC-32.
    func stream(_ entry: Entry, write: (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.method) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.uint32(at: 0) == 0x0403_4b50 else { throw ZipError.corrupt(entry.path) }
        let skip = UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + skip)
        var crc = CRC32()
        var remaining = entry.compressedSize
        let chunk = 1 << 20
        if entry.method == 0 {
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty else {
                    throw ZipError.truncated
                }
                remaining -= UInt64(data.count)
                crc.update(data)
                try write(data)
            }
        } else {
            var inflater = try Inflater()
            var produced: UInt64 = 0
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty else {
                    throw ZipError.truncated
                }
                remaining -= UInt64(data.count)
                try inflater.process(data, final: remaining == 0) { output in
                    produced += UInt64(output.count)
                    crc.update(output)
                    try write(output)
                }
            }
            guard produced == entry.size else { throw ZipError.corrupt(entry.path) }
        }
        guard crc.value == entry.crc32 else { throw ZipError.checksumMismatch(entry.path) }
    }
}

/// Raw DEFLATE decompression with the Compression framework (`COMPRESSION_ZLIB` is raw DEFLATE, as in ZIP).
///
/// Holds a pointer to the framework's stream state; used by one thread at a time inside `ZipReader.stream`.
struct Inflater: ~Copyable {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 1 << 20

    init() throws {
        stream = .allocate(capacity: 1)
        buffer = .allocate(capacity: bufferSize)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            buffer.deallocate()
            throw ZipReader.ZipError.corrupt("deflate")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        buffer.deallocate()
    }

    mutating func process(_ input: Data, final: Bool, output: (Data) throws -> Void) throws {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                let written = bufferSize - stream.pointee.dst_size
                if written > 0 { try output(Data(bytes: buffer, count: written)) }
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK:
                    // The framework hands out at most 64 KiB per call: go on until a call that has all input brings
                    // nothing more. The last piece must end the stream; one that stops bringing output is cut short.
                    if written == 0 && stream.pointee.src_size == 0 {
                        if final { throw ZipReader.ZipError.corrupt("deflate") }
                        return
                    }
                default: throw ZipReader.ZipError.corrupt("deflate")
                }
            }
        }
    }
}

/// CRC-32 (IEEE 802.3), as ZIP uses it.
struct CRC32 {
    private(set) var value: UInt32 = 0

    static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    mutating func update(_ data: Data) {
        var crc = ~value
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            Self.table.withUnsafeBufferPointer { table in
                for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        value = ~crc
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[start + $1]) << (8 * $1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[start + $1]) << (8 * $1) }
    }
}
