import Foundation

/// Нестрогая навигация по JSON — аналог хелперов `obj/str/int/arr` из Kotlin-кода:
/// отсутствующий ключ, `null` и чужой тип дают `nil`.
typealias JSONObject = [String: Any]

enum JSON {
    static func object(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? JSONObject
    }

    static func object(_ text: String) -> JSONObject? {
        object(Data(text.utf8))
    }

    static func array(_ data: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [Any]
    }

    static func data(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data()
    }

    static func string(_ value: Any) -> String {
        String(data: data(value), encoding: .utf8) ?? ""
    }

    fileprivate static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

extension Dictionary where Key == String, Value == Any {
    func obj(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
    }

    func arr(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// Массив объектов (элементы другого типа пропускаются).
    func objects(_ key: String) -> [JSONObject] {
        (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }

    /// Содержимое примитива строкой: числа и булевы значения тоже превращаются в текст.
    func str(_ key: String) -> String? {
        switch self[key] {
        case let s as String: return s
        case let n as NSNumber: return JSON.isBool(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case let n as NSNumber:
            if JSON.isBool(n) { return nil }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 9.0e18 ? n.intValue : nil
        case let s as String: return Int(s)
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: return JSON.isBool(n) ? nil : n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let n as NSNumber: return JSON.isBool(n) ? n.boolValue : nil
        case let s as String: return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }
}

extension String {
    /// Kotlin `substringAfterLast`: если разделителя нет — вся строка.
    func substringAfterLast(_ separator: Character) -> String {
        guard let idx = lastIndex(of: separator) else { return self }
        return String(self[index(after: idx)...])
    }
}
