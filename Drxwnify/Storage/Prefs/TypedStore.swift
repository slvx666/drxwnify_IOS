import Foundation
import Combine

/// Хранилище «ключ → типизированное значение» поверх `UserDefaults` (свой suite) и Keychain.
/// Служит и аналогом DataStore (`settings.preferences_pb`), и аналогом файлов SharedPreferences.
///
/// - Обычные значения лежат в `UserDefaults(suiteName:)` под теми же именами, что на Android.
/// - Типы значений (int/long, float/double, набор строк) лежат рядом, в служебном ключе:
///   без них нельзя записать копию обратно в формат Android.
/// - Секретные ключи лежат в Keychain под учётной записью `<suite>/<ключ>`.
final class TypedStore: ObservableObject {
    /// Срабатывает после любого изменения. Значение — имя ключа или `nil`, если изменилось всё.
    let changes = PassthroughSubject<String?, Never>()

    let suiteName: String
    private let defaults: UserDefaults
    private let isSecret: (String) -> Bool
    private let lock = NSRecursiveLock()

    private static let kindsKey = "\u{1}kinds"

    init(suiteName: String, isSecret: @escaping (String) -> Bool = { _ in false }) {
        self.suiteName = suiteName
        self.isSecret = isSecret
        // suiteName всегда валиден (не совпадает с bundle id), поэтому `!` безопасен.
        self.defaults = UserDefaults(suiteName: suiteName)!
    }

    private func account(_ key: String) -> String { "\(suiteName)/\(key)" }

    private var kinds: [String: String] {
        get { defaults.dictionary(forKey: Self.kindsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.kindsKey) }
    }

    // MARK: Сырые значения

    func value(_ key: String) -> PrefValue? {
        lock.lock(); defer { lock.unlock() }
        if isSecret(key) {
            guard let data = Keychain.data(account(key)) else { return nil }
            return try? JSONDecoder().decode(PrefValue.self, from: data)
        }
        guard let object = defaults.object(forKey: key),
              let raw = kinds[key], let kind = PrefKind(rawValue: raw) else { return nil }
        return PrefValue(plistObject: object, kind: kind)
    }

    func setValue(_ value: PrefValue?, for key: String) {
        lock.lock()
        write(value, for: key)
        lock.unlock()
        notify(key)
    }

    private func write(_ value: PrefValue?, for key: String) {
        if isSecret(key) {
            if let value = value, let data = try? JSONEncoder().encode(value) {
                Keychain.set(data, for: account(key))
            } else {
                Keychain.remove(account(key))
            }
            return
        }
        var k = kinds
        if let value = value {
            defaults.set(value.plistObject, forKey: key)
            k[key] = value.kind.rawValue
        } else {
            defaults.removeObject(forKey: key)
            k[key] = nil
        }
        kinds = k
    }

    /// Все значения, включая секретные.
    func allValues() -> [String: PrefValue] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: PrefValue] = [:]
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let k = kinds
        for (key, object) in domain where key != Self.kindsKey {
            if let raw = k[key], let kind = PrefKind(rawValue: raw),
               let value = PrefValue(plistObject: object, kind: kind) {
                out[key] = value
            }
        }
        let prefix = suiteName + "/"
        for acc in Keychain.accounts(prefix: prefix) {
            let key = String(acc.dropFirst(prefix.count))
            if let data = Keychain.data(acc), let value = try? JSONDecoder().decode(PrefValue.self, from: data) {
                out[key] = value
            }
        }
        return out
    }

    /// Полная замена содержимого (восстановление из копии).
    func replaceAll(_ values: [String: PrefValue]) {
        lock.lock()
        defaults.removePersistentDomain(forName: suiteName)
        let prefix = suiteName + "/"
        for acc in Keychain.accounts(prefix: prefix) { Keychain.remove(acc) }
        var plain: [String: Any] = [:]
        var k: [String: String] = [:]
        for (key, value) in values {
            if isSecret(key) {
                if let data = try? JSONEncoder().encode(value) { Keychain.set(data, for: account(key)) }
            } else {
                plain[key] = value.plistObject
                k[key] = value.kind.rawValue
            }
        }
        plain[Self.kindsKey] = k
        defaults.setPersistentDomain(plain, forName: suiteName)
        lock.unlock()
        notify(nil)
    }

    var isEmpty: Bool { allValues().isEmpty }

    private func notify(_ key: String?) {
        let send = { [weak self] in
            guard let self = self else { return }
            self.objectWillChange.send()
            self.changes.send(key)
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    // MARK: Типизированный доступ

    func get<T>(_ key: PrefKey<T>) -> T? {
        value(key.name).flatMap(T.fromPref)
    }

    func get<T>(_ key: PrefKey<T>, default def: T) -> T {
        get(key) ?? def
    }

    func set<T>(_ key: PrefKey<T>, _ newValue: T?) {
        setValue(newValue?.toPref(key.kind), for: key.name)
    }

    func remove(_ key: String) {
        setValue(nil, for: key)
    }

    // Доступ по имени (для SharedPreferences, где ключи не описаны заранее).

    func string(_ key: String) -> String? { value(key).flatMap(String.fromPref) }
    func bool(_ key: String) -> Bool? { value(key).flatMap(Bool.fromPref) }
    func int(_ key: String) -> Int? { value(key).flatMap(Int.fromPref) }
    func stringSet(_ key: String) -> [String]? { value(key).flatMap([String].fromPref) }

    func setString(_ value: String?, for key: String) { setValue(value.map { .string($0) }, for: key) }
    func setBool(_ value: Bool?, for key: String) { setValue(value.map { .bool($0) }, for: key) }
    func setLong(_ value: Int?, for key: String) { setValue(value.map { .long(Int64($0)) }, for: key) }
    func setInt(_ value: Int?, for key: String) { setValue(value.map { .int(Int32(truncatingIfNeeded: $0)) }, for: key) }
    func setStringSet(_ value: [String]?, for key: String) { setValue(value.map { .stringSet($0) }, for: key) }
}
