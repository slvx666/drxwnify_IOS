import Foundation

/// Закреплённое наверху библиотеки долгим нажатием (`catalog/LibraryPins.kt`), только на этом телефоне.
/// Хранится как на Android — SharedPreferences `library_pins`, ключ `pinned` (JSON-массив), поэтому
/// приезжает с резервной копией. Ключи: `spotify:album:<id>` (uri), `meld:playlist:<id>` (свой плейлист), `meld:liked`.
final class LibraryPins: ObservableObject {
    static let shared = LibraryPins()
    @Published private(set) var pinned: [String] = []
    /// Тот же suite, что `Prefs.shared("library_pins")` — туда кладёт восстановление копии.
    private let store = TypedStore(suiteName: "sp.library_pins")

    private init() {
        reload()
        // Закрепления прежних iOS-сборок (свой suite) переносятся один раз.
        if let old = UserDefaults(suiteName: "library_pins")?.string(forKey: "pinned") {
            let extra = (JSON.array(Data(old.utf8)) ?? []).compactMap { $0 as? String }.filter { !pinned.contains($0) }
            if !extra.isEmpty { pinned += extra; save() }
            UserDefaults(suiteName: "library_pins")?.removeObject(forKey: "pinned")
        }
    }

    /// После восстановления копии.
    func reload() {
        let raw = store.string("pinned") ?? "[]"
        pinned = (JSON.array(Data(raw.utf8)) ?? []).compactMap { $0 as? String }
    }

    static func key(_ e: SpotifyLibraryEntry) -> String {
        if e.kind == .likedSongs { return "meld:liked" }
        return e.uri.isEmpty ? e.id : e.uri
    }

    static func localKey(_ playlistId: String) -> String { "meld:playlist:" + playlistId }

    func index(_ key: String) -> Int? { pinned.firstIndex(of: key) }

    /// Закрепляет или открепляет; возвращает, закреплено ли теперь.
    @discardableResult
    func toggle(_ key: String) -> Bool {
        if let i = pinned.firstIndex(of: key) { pinned.remove(at: i) } else { pinned.append(key) }
        save()
        return pinned.contains(key)
    }

    private func save() { store.setString(JSON.string(pinned), for: "pinned") }
}
