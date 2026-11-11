import Foundation

/// Запрещённые треки (Android 2.2.5, `playback/BlockedTracks.kt`): блёклые, с ⊘, плеер их пропускает.
/// Хранятся как на Android — файл `blocked_tracks`, ключ `keys` (набор id каталога), поэтому переносятся резервной копией.
final class BlockedTracks: ObservableObject {
    static let shared = BlockedTracks()
    static let file = "blocked_tracks"
    static let key = "keys"

    @Published private(set) var keys = Set<String>()
    private var store: TypedStore?

    func configure(_ prefs: Prefs) {
        store = prefs.shared(Self.file)
        reload()
    }

    func reload() {
        keys = Set(store?.stringSet(Self.key) ?? [])
    }

    /// Ключ трека: id каталога, иначе собственный id (как `keyOf`).
    static func keyOf(_ t: Track) -> String { t.catalogId ?? t.id }

    func isBlocked(_ t: Track) -> Bool {
        !keys.isEmpty && (keys.contains(Self.keyOf(t)) || keys.contains(t.id))
    }

    func set(_ tracks: [Track], blocked: Bool) {
        let ks = tracks.map(Self.keyOf)
        guard !ks.isEmpty else { return }
        if blocked { keys.formUnion(ks) } else { keys.subtract(ks); tracks.forEach { keys.remove($0.id) } }
        store?.setStringSet(Array(keys), for: Self.key)
    }
}
