import Foundation

/// Все настройки приложения: аналог DataStore и набора файлов SharedPreferences Android.
final class Prefs {
    /// Аналог `settings.preferences_pb` (ключи — `PK.*`).
    let settings: TypedStore

    private var files: [String: TypedStore] = [:]
    private let lock = NSLock()
    private let registry = UserDefaults.standard
    private static let registryKey = "sharedPrefsFiles"

    /// Ключи DataStore, которые хранятся в Keychain.
    static let secretSettings: Set<String> = [
        "spotifySpDc", "spotifySpKey", "spotifyAccessToken",
        "yandexAccessToken", "vkAccessToken", "innerTubeCookie",
        "lastfmSession", "listenTogetherSessionToken", "discordToken",
        "proxyPassword", "soulseekPassword", "openRouterApiKey", "deeplApiKey",
    ]

    /// Секреты в файлах SharedPreferences: приватный ключ друзей и данные входа VK.
    static func isSecret(file: String, key: String) -> Bool {
        switch file {
        case "friends": return key == "sk"
        case "vk_login": return true
        default: return false
        }
    }

    init() {
        settings = TypedStore(suiteName: "ds.settings", isSecret: { Prefs.secretSettings.contains($0) })
    }

    /// Аналог `context.getSharedPreferences(name, MODE_PRIVATE)`.
    func shared(_ name: String) -> TypedStore {
        lock.lock(); defer { lock.unlock() }
        if let store = files[name] { return store }
        let store = TypedStore(suiteName: "sp." + name, isSecret: { Prefs.isSecret(file: name, key: $0) })
        files[name] = store
        var known = registry.stringArray(forKey: Self.registryKey) ?? []
        if !known.contains(name) {
            known.append(name)
            registry.set(known, forKey: Self.registryKey)
        }
        return store
    }

    /// Имена всех когда-либо открытых файлов SharedPreferences.
    var sharedFileNames: [String] {
        (registry.stringArray(forKey: Self.registryKey) ?? []).sorted()
    }

    /// Удаляет все файлы SharedPreferences (перед восстановлением из копии).
    func removeAllShared() {
        for name in sharedFileNames { shared(name).replaceAll([:]) }
        lock.lock()
        registry.removeObject(forKey: Self.registryKey)
        files.removeAll()
        lock.unlock()
    }
}
