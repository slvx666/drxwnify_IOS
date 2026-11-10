import Foundation

/// Чтение и запись `settings.preferences_pb` — protobuf `androidx.datastore.preferences`:
///
///     message PreferenceMap { map<string, Value> preferences = 1; }
///     message Value { oneof value {
///         bool boolean = 1; float float = 2; int32 integer = 3; int64 long = 4;
///         string string = 5; StringSet string_set = 6; double double = 7; bytes bytes = 8; } }
///     message StringSet { repeated string strings = 1; }
enum PreferencesProto {
    enum ProtoError: Error { case truncated, badWireType, badUTF8 }

    // MARK: Разбор

    static func decode(_ data: Data) throws -> [String: PrefValue] {
        var out: [String: PrefValue] = [:]
        var r = Reader([UInt8](data))
        while !r.atEnd {
            let (field, wire) = try r.tag()
            if field == 1 && wire == 2 {
                var entry = Reader(try r.bytes())
                var key: String?
                var value: PrefValue?
                while !entry.atEnd {
                    let (f, w) = try entry.tag()
                    if f == 1 && w == 2 {
                        key = try entry.string()
                    } else if f == 2 && w == 2 {
                        value = try decodeValue(try entry.bytes())
                    } else {
                        try entry.skip(w)
                    }
                }
                if let key = key, let value = value { out[key] = value }
            } else {
                try r.skip(wire)
            }
        }
        return out
    }

    private static func decodeValue(_ bytes: [UInt8]) throws -> PrefValue? {
        var r = Reader(bytes)
        var value: PrefValue?
        while !r.atEnd {
            let (f, w) = try r.tag()
            switch (f, w) {
            case (1, 0): value = .bool(try r.varint() != 0)
            case (2, 5): value = .float(Float(bitPattern: try r.fixed32()))
            case (3, 0): value = .int(Int32(truncatingIfNeeded: try r.varint()))
            case (4, 0): value = .long(Int64(bitPattern: try r.varint()))
            case (5, 2): value = .string(try r.string())
            case (6, 2):
                var set = Reader(try r.bytes())
                var strings: [String] = []
                while !set.atEnd {
                    let (sf, sw) = try set.tag()
                    if sf == 1 && sw == 2 { strings.append(try set.string()) } else { try set.skip(sw) }
                }
                value = .stringSet(strings)
            case (7, 1): value = .double(Double(bitPattern: try r.fixed64()))
            case (8, 2): value = .bytes(Data(try r.bytes()))
            default: try r.skip(w)
            }
        }
        return value
    }

    // MARK: Запись

    static func encode(_ values: [String: PrefValue]) -> Data {
        var out = Writer()
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            var entry = Writer()
            entry.tag(1, 2); entry.lengthDelimited(Array(key.utf8))
            entry.tag(2, 2); entry.lengthDelimited(encodeValue(value))
            out.tag(1, 2); out.lengthDelimited(entry.bytes)
        }
        return Data(out.bytes)
    }

    private static func encodeValue(_ value: PrefValue) -> [UInt8] {
        var w = Writer()
        switch value {
        case .bool(let v): w.tag(1, 0); w.varint(v ? 1 : 0)
        case .float(let v): w.tag(2, 5); w.fixed32(v.bitPattern)
        case .int(let v): w.tag(3, 0); w.varint(UInt64(bitPattern: Int64(v)))
        case .long(let v): w.tag(4, 0); w.varint(UInt64(bitPattern: v))
        case .string(let v): w.tag(5, 2); w.lengthDelimited(Array(v.utf8))
        case .stringSet(let v):
            var set = Writer()
            for s in v { set.tag(1, 2); set.lengthDelimited(Array(s.utf8)) }
            w.tag(6, 2); w.lengthDelimited(set.bytes)
        case .double(let v): w.tag(7, 1); w.fixed64(v.bitPattern)
        case .bytes(let v): w.tag(8, 2); w.lengthDelimited([UInt8](v))
        }
        return w.bytes
    }

    // MARK: Примитивы protobuf

    struct Reader {
        private let buf: [UInt8]
        private var pos = 0

        init(_ buf: [UInt8]) { self.buf = buf }

        var atEnd: Bool { pos >= buf.count }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard pos < buf.count, shift < 64 else { throw ProtoError.truncated }
                let b = buf[pos]; pos += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        mutating func tag() throws -> (Int, Int) {
            let t = try varint()
            return (Int(t >> 3), Int(t & 7))
        }

        mutating func bytes() throws -> [UInt8] {
            let n = Int(try varint())
            guard n >= 0, pos + n <= buf.count else { throw ProtoError.truncated }
            defer { pos += n }
            return Array(buf[pos..<pos + n])
        }

        mutating func string() throws -> String {
            guard let s = String(bytes: try bytes(), encoding: .utf8) else { throw ProtoError.badUTF8 }
            return s
        }

        mutating func fixed32() throws -> UInt32 {
            guard pos + 4 <= buf.count else { throw ProtoError.truncated }
            defer { pos += 4 }
            return UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | UInt32(buf[pos + 3]) << 24
        }

        mutating func fixed64() throws -> UInt64 {
            guard pos + 8 <= buf.count else { throw ProtoError.truncated }
            defer { pos += 8 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(buf[pos + i]) << UInt64(8 * i) }
            return v
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: _ = try fixed64()
            case 2: _ = try bytes()
            case 5: _ = try fixed32()
            default: throw ProtoError.badWireType
            }
        }
    }

    struct Writer {
        private(set) var bytes: [UInt8] = []

        mutating func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 {
                bytes.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            bytes.append(UInt8(v))
        }

        mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

        mutating func lengthDelimited(_ data: [UInt8]) {
            varint(UInt64(data.count))
            bytes.append(contentsOf: data)
        }

        mutating func fixed32(_ v: UInt32) {
            for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * i))) }
        }

        mutating func fixed64(_ v: UInt64) {
            for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) }
        }
    }
}
