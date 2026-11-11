import Foundation

/// Закреплённое наверху библиотеки долгим нажатием (`catalog/LibraryPins.kt`), только на этом телефоне:
/// свои закрепления идут первыми, в порядке закрепления; закрепления аккаунта Spotify остаются как есть.
final class LibraryPins: ObservableObject {
    static let shared = LibraryPins()
    @Published private(set) var pinned: [String]
    private let defaults = UserDefaults(suiteName: "library_pins") ?? .standard

    private init() {
        let raw = defaults.string(forKey: "pinned") ?? "[]"
        pinned = (JSON.array(Data(raw.utf8)) ?? []).compactMap { $0 as? String }
    }

    static func key(_ e: SpotifyLibraryEntry) -> String { e.uri.isEmpty ? e.id : e.uri }

    /// Закрепляет или открепляет; возвращает, закреплено ли теперь.
    @discardableResult
    func toggle(_ key: String) -> Bool {
        if let i = pinned.firstIndex(of: key) { pinned.remove(at: i) } else { pinned.append(key) }
        defaults.set(JSON.string(pinned), forKey: "pinned")
        return pinned.contains(key)
    }
}
