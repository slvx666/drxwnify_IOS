import Foundation

/// Удалённая конфигурация проекта — перенос `utils/RemoteConfig.kt`: общий VK, lossless-зеркала, отключённые источники.
/// Читается с сайта проекта, при недоступности — с GitHub; обновляется раз в 6 часов, последняя копия лежит в UserDefaults.
final class RemoteConfig {
    struct VkShared {
        var token: String
        var dailyTracks: Int
    }

    struct Config {
        var vkShared: VkShared?
        var losslessMirrors: [String] = []
        var disabledSources: Set<String> = []
    }

    static let shared = RemoteConfig()

    private static let urls = [
        "https://drxwnify.pages.dev/config.json",
        "https://raw.githubusercontent.com/slvx666/DRXWNIFY/master/website/config.json",
    ]
    private static let refreshInterval: TimeInterval = 6 * 3600
    private static let cacheKey = "remoteConfigJson"
    private static let fetchedKey = "remoteConfigFetchedAt"

    private let lock = NSLock()
    private var value = Config()

    var config: Config {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    private init() {
        if let cached = UserDefaults.standard.string(forKey: Self.cacheKey), let c = Self.parse(cached) { value = c }
    }

    static func parse(_ text: String) -> Config? {
        guard let root = JSON.object(text) else { return nil }
        var c = Config()
        if let vk = root.obj("vkShared"), let token = vk.str("token"), !token.trimmingCharacters(in: .whitespaces).isEmpty {
            c.vkShared = VkShared(token: token, dailyTracks: vk.int("dailyTracks") ?? 40)
        }
        c.losslessMirrors = (root.arr("losslessMirrors") ?? []).compactMap { item -> String? in
            guard var u = (item as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
            while u.hasSuffix("/") { u.removeLast() }
            return u.hasPrefix("https://") ? u : nil
        }
        c.disabledSources = Set((root.arr("disabledSources") ?? []).compactMap { ($0 as? String)?.uppercased() })
        return c
    }

    /// Обновляет конфигурацию, если прошлая старше 6 часов.
    func refreshIfNeeded() async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.fetchedKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.refreshInterval { return }
        for s in Self.urls {
            guard let url = URL(string: s), let r = try? await HTTP.get(url, timeout: 10), r.isSuccess,
                  let parsed = Self.parse(r.text) else { continue }
            lock.lock()
            value = parsed
            lock.unlock()
            defaults.set(r.text, forKey: Self.cacheKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.fetchedKey)
            return
        }
    }
}
