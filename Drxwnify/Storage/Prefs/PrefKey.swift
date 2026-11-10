import Foundation

/// Тип значения настройки. Совпадает с типами Android DataStore Preferences и SharedPreferences.
enum PrefKind: String, Codable {
    case bool, float, int, long, string, stringSet, double, bytes
}

/// Значение настройки с типом.
enum PrefValue: Equatable {
    case bool(Bool)
    case float(Float)
    case int(Int32)
    case long(Int64)
    case string(String)
    case stringSet([String])
    case double(Double)
    case bytes(Data)

    var kind: PrefKind {
        switch self {
        case .bool: return .bool
        case .float: return .float
        case .int: return .int
        case .long: return .long
        case .string: return .string
        case .stringSet: return .stringSet
        case .double: return .double
        case .bytes: return .bytes
        }
    }

    /// Значение в виде, пригодном для `UserDefaults`.
    var plistObject: Any {
        switch self {
        case .bool(let v): return v
        case .float(let v): return v
        case .int(let v): return Int(v)
        case .long(let v): return Int(v)
        case .string(let v): return v
        case .stringSet(let v): return v
        case .double(let v): return v
        case .bytes(let v): return v
        }
    }

    init?(plistObject: Any, kind: PrefKind) {
        switch kind {
        case .bool:
            guard let v = plistObject as? Bool else { return nil }
            self = .bool(v)
        case .float:
            guard let v = plistObject as? NSNumber else { return nil }
            self = .float(v.floatValue)
        case .int:
            guard let v = plistObject as? NSNumber else { return nil }
            self = .int(v.int32Value)
        case .long:
            guard let v = plistObject as? NSNumber else { return nil }
            self = .long(v.int64Value)
        case .string:
            guard let v = plistObject as? String else { return nil }
            self = .string(v)
        case .stringSet:
            guard let v = plistObject as? [String] else { return nil }
            self = .stringSet(v)
        case .double:
            guard let v = plistObject as? NSNumber else { return nil }
            self = .double(v.doubleValue)
        case .bytes:
            guard let v = plistObject as? Data else { return nil }
            self = .bytes(v)
        }
    }
}

extension PrefValue: Codable {
    private enum CodingKeys: String, CodingKey { case k, v }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(PrefKind.self, forKey: .k)
        switch kind {
        case .bool: self = .bool(try c.decode(Bool.self, forKey: .v))
        case .float: self = .float(try c.decode(Float.self, forKey: .v))
        case .int: self = .int(try c.decode(Int32.self, forKey: .v))
        case .long: self = .long(try c.decode(Int64.self, forKey: .v))
        case .string: self = .string(try c.decode(String.self, forKey: .v))
        case .stringSet: self = .stringSet(try c.decode([String].self, forKey: .v))
        case .double: self = .double(try c.decode(Double.self, forKey: .v))
        case .bytes: self = .bytes(try c.decode(Data.self, forKey: .v))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .k)
        switch self {
        case .bool(let v): try c.encode(v, forKey: .v)
        case .float(let v): try c.encode(v, forKey: .v)
        case .int(let v): try c.encode(v, forKey: .v)
        case .long(let v): try c.encode(v, forKey: .v)
        case .string(let v): try c.encode(v, forKey: .v)
        case .stringSet(let v): try c.encode(v, forKey: .v)
        case .double(let v): try c.encode(v, forKey: .v)
        case .bytes(let v): try c.encode(v, forKey: .v)
        }
    }
}

/// Типы Swift, которые можно хранить в настройках.
protocol PrefStorable {
    static func fromPref(_ value: PrefValue) -> Self?
    func toPref(_ kind: PrefKind) -> PrefValue
}

extension Bool: PrefStorable {
    static func fromPref(_ value: PrefValue) -> Bool? {
        if case .bool(let v) = value { return v }
        return nil
    }
    func toPref(_ kind: PrefKind) -> PrefValue { .bool(self) }
}

extension Float: PrefStorable {
    static func fromPref(_ value: PrefValue) -> Float? {
        switch value {
        case .float(let v): return v
        case .double(let v): return Float(v)
        default: return nil
        }
    }
    func toPref(_ kind: PrefKind) -> PrefValue { kind == .double ? .double(Double(self)) : .float(self) }
}

extension Double: PrefStorable {
    static func fromPref(_ value: PrefValue) -> Double? {
        switch value {
        case .double(let v): return v
        case .float(let v): return Double(v)
        default: return nil
        }
    }
    func toPref(_ kind: PrefKind) -> PrefValue { kind == .float ? .float(Float(self)) : .double(self) }
}

extension Int: PrefStorable {
    static func fromPref(_ value: PrefValue) -> Int? {
        switch value {
        case .int(let v): return Int(v)
        case .long(let v): return Int(v)
        default: return nil
        }
    }
    func toPref(_ kind: PrefKind) -> PrefValue {
        kind == .int ? .int(Int32(truncatingIfNeeded: self)) : .long(Int64(self))
    }
}

extension String: PrefStorable {
    static func fromPref(_ value: PrefValue) -> String? {
        if case .string(let v) = value { return v }
        return nil
    }
    func toPref(_ kind: PrefKind) -> PrefValue { .string(self) }
}

extension Array: PrefStorable where Element == String {
    static func fromPref(_ value: PrefValue) -> [String]? {
        if case .stringSet(let v) = value { return v }
        return nil
    }
    func toPref(_ kind: PrefKind) -> PrefValue { .stringSet(self) }
}

extension Data: PrefStorable {
    static func fromPref(_ value: PrefValue) -> Data? {
        if case .bytes(let v) = value { return v }
        return nil
    }
    func toPref(_ kind: PrefKind) -> PrefValue { .bytes(self) }
}

/// Типизированный ключ настройки. Имя совпадает с Android.
struct PrefKey<Value: PrefStorable> {
    let name: String
    let kind: PrefKind

    init(_ name: String, _ kind: PrefKind) {
        self.name = name
        self.kind = kind
    }
}
