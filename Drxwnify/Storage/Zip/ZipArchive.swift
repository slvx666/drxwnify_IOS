import Foundation
import Compression
import zlib

enum ZipError: Error, LocalizedError {
    case notZip, zip64Unsupported, badEntry(String), unsupportedMethod(Int), crcMismatch(String), io

    var errorDescription: String? {
        switch self {
        case .notZip: return "Файл не является zip-архивом"
        case .zip64Unsupported: return "Архивы ZIP64 не поддерживаются"
        case .badEntry(let n): return "Повреждена запись архива: \(n)"
        case .unsupportedMethod(let m): return "Неизвестный метод сжатия: \(m)"
        case .crcMismatch(let n): return "Ошибка контрольной суммы: \(n)"
        case .io: return "Ошибка чтения или записи файла"
        }
    }
}

/// Минимальное чтение zip (stored и deflate) по центральному каталогу.
/// Java `ZipOutputStream` пишет размеры в data descriptor, поэтому локальным заголовкам верить нельзя.
final class ZipReader {
    struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        fileprivate let localOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ZipError.io }
        self.data = data
        self.entries = try Self.readDirectory(data)
    }

    private static func u16(_ d: Data, _ o: Int) -> Int {
        Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> Int {
        u16(d, o) | u16(d, o + 2) << 16
    }

    private static func readDirectory(_ d: Data) throws -> [Entry] {
        let count = d.count
        guard count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = count - 22
        let stop = max(0, count - 22 - 65535)
        while i >= stop {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let total = u16(d, eocd + 10)
        let cdOffset = u32(d, eocd + 16)
        if total == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }

        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= count, u32(d, p) == 0x02014b50 else { throw ZipError.badEntry("каталог") }
            let method = u16(d, p + 10)
            let crc = UInt32(truncatingIfNeeded: u32(d, p + 16))
            let compSize = u32(d, p + 20)
            let uncompSize = u32(d, p + 24)
            let nameLen = u16(d, p + 28)
            let extraLen = u16(d, p + 30)
            let commentLen = u16(d, p + 32)
            let localOffset = u32(d, p + 42)
            guard p + 46 + nameLen <= count else { throw ZipError.badEntry("каталог") }
            let nameData = d.subdata(in: d.startIndex + p + 46 ..< d.startIndex + p + 46 + nameLen)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
            entries.append(Entry(name: name, method: method, crc: crc, compressedSize: compSize,
                                 uncompressedSize: uncompSize, localOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private func payloadRange(_ e: Entry) throws -> Range<Data.Index> {
        let o = e.localOffset
        guard o + 30 <= data.count, Self.u32(data, o) == 0x04034b50 else { throw ZipError.badEntry(e.name) }
        let start = o + 30 + Self.u16(data, o + 26) + Self.u16(data, o + 28)
        guard start + e.compressedSize <= data.count else { throw ZipError.badEntry(e.name) }
        return data.startIndex + start ..< data.startIndex + start + e.compressedSize
    }

    /// Распаковывает запись, отдавая данные кусками.
    func read(_ e: Entry, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let range = try payloadRange(e)
        var crc: UInt = 0
        func checked(_ chunk: UnsafeRawBufferPointer) throws {
            crc = UInt(crc32(uLong(crc), chunk.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)))
            try sink(chunk)
        }
        switch e.method {
        case 0:
            let chunkSize = 1 << 20
            var pos = range.lowerBound
            while pos < range.upperBound {
                let end = min(pos + chunkSize, range.upperBound)
                try data.subdata(in: pos..<end).withUnsafeBytes { try checked($0) }
                pos = end
            }
        case 8:
            try Deflate.run(.decode, input: data, range: range, sink: checked)
        default:
            throw ZipError.unsupportedMethod(e.method)
        }
        if UInt32(truncatingIfNeeded: crc) != e.crc { throw ZipError.crcMismatch(e.name) }
    }

    func data(for e: Entry) throws -> Data {
        var out = Data()
        out.reserveCapacity(e.uncompressedSize)
        try read(e) { out.append(contentsOf: $0) }
        return out
    }

    func extract(_ e: Entry, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw ZipError.io }
        defer { try? handle.close() }
        try read(e) { try handle.write(contentsOf: Data($0)) }
    }
}

/// Запись zip (deflate), которую читает и Java `ZipInputStream`:
/// размеры и CRC стоят в локальных заголовках, без data descriptor.
final class ZipWriter {
    private struct Record {
        let name: [UInt8]
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let offset: Int
    }

    private let handle: FileHandle
    private var records: [Record] = []
    private var offset = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw ZipError.io }
        self.handle = handle
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

    // 1980-01-01 00:00: время в копии не важно.
    private static let dosTime = le16(0)
    private static let dosDate = le16(0x0021)

    private func localHeader(name: [UInt8], crc: UInt32, comp: Int, uncomp: Int) -> [UInt8] {
        var h: [UInt8] = []
        h += Self.le32(0x04034b50)
        h += Self.le16(20)          // версия для распаковки
        h += Self.le16(0x0800)      // имена в UTF-8
        h += Self.le16(8)           // deflate
        h += Self.dosTime + Self.dosDate
        h += Self.le32(Int(crc)) + Self.le32(comp) + Self.le32(uncomp)
        h += Self.le16(name.count) + Self.le16(0)
        h += name
        return h
    }

    func add(name: String, fileAt url: URL) throws {
        guard let input = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ZipError.io }
        try add(name: name, data: input)
    }

    func add(name: String, data input: Data) throws {
        let nameBytes = Array(name.utf8)
        let start = offset
        let placeholder = localHeader(name: nameBytes, crc: 0, comp: 0, uncomp: 0)
        try handle.write(contentsOf: Data(placeholder))

        let uncomp = input.count
        var comp = 0
        let crc: UInt = input.withUnsafeBytes { chunk in
            UInt(crc32(0, chunk.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)))
        }
        try Deflate.run(.encode, input: input, range: input.startIndex..<input.endIndex) { out in
            comp += out.count
            try self.handle.write(contentsOf: Data(out))
        }
        guard uncomp < 0xFFFF_FFFF, comp < 0xFFFF_FFFF else { throw ZipError.zip64Unsupported }

        let crc32Value = UInt32(truncatingIfNeeded: crc)
        let end = start + placeholder.count + comp
        try handle.seek(toOffset: UInt64(start))
        try handle.write(contentsOf: Data(localHeader(name: nameBytes, crc: crc32Value, comp: comp, uncomp: uncomp)))
        try handle.seek(toOffset: UInt64(end))
        offset = end
        records.append(Record(name: nameBytes, crc: crc32Value, compressedSize: comp, uncompressedSize: uncomp, offset: start))
    }

    func finish() throws {
        let cdStart = offset
        var cd: [UInt8] = []
        for r in records {
            cd += Self.le32(0x02014b50)
            cd += Self.le16(20) + Self.le16(20)
            cd += Self.le16(0x0800)
            cd += Self.le16(8)
            cd += Self.dosTime + Self.dosDate
            cd += Self.le32(Int(r.crc)) + Self.le32(r.compressedSize) + Self.le32(r.uncompressedSize)
            cd += Self.le16(r.name.count) + Self.le16(0) + Self.le16(0)
            cd += Self.le16(0) + Self.le16(0)
            cd += Self.le32(0)
            cd += Self.le32(r.offset)
            cd += r.name
        }
        var eocd: [UInt8] = []
        eocd += Self.le32(0x06054b50)
        eocd += Self.le16(0) + Self.le16(0)
        eocd += Self.le16(records.count) + Self.le16(records.count)
        eocd += Self.le32(cd.count) + Self.le32(cdStart)
        eocd += Self.le16(0)
        try handle.write(contentsOf: Data(cd + eocd))
        try handle.close()
    }
}

/// Потоковый raw DEFLATE (RFC 1951) через системный Compression.
enum Deflate {
    enum Mode { case encode, decode }

    static func run(_ mode: Mode, input: Data, range: Range<Data.Index>,
                    sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        let op: compression_stream_operation = mode == .encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(streamPtr, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.io
        }
        defer { compression_stream_destroy(streamPtr) }

        let outSize = 1 << 18
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { outBuf.deallocate() }

        let slice = input.subdata(in: range)
        try slice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { empty.deallocate() }
            streamPtr.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress.map { UnsafePointer($0) } ?? UnsafePointer(empty)
            streamPtr.pointee.src_size = raw.count
            streamPtr.pointee.dst_ptr = outBuf
            streamPtr.pointee.dst_size = outSize
            while true {
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = outSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    try sink(UnsafeRawBufferPointer(start: outBuf, count: produced))
                    streamPtr.pointee.dst_ptr = outBuf
                    streamPtr.pointee.dst_size = outSize
                }
                if status == COMPRESSION_STATUS_END { break }
                if status != COMPRESSION_STATUS_OK { throw ZipError.io }
                if produced == 0 && streamPtr.pointee.src_size == 0 { throw ZipError.io }
            }
        }
    }
}
