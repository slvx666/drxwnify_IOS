import Foundation
import Combine
import GRDB

/// Лайки треков: `song.liked` в базе и, если включена синхронизация (`spotifySyncLikes`), «Любимые треки» Spotify (INT-008).
final class LikeManager: ObservableObject {
    /// Идентификаторы (`Track.id`) понравившихся треков.
    @Published private(set) var liked = Set<String>()

    private let database: AppDatabase
    private let settings: TypedStore
    private let spotify: SpotifyAPI
    private var checked = Set<String>()
    private var cancellable: AnyCancellable?

    init(database: AppDatabase, settings: TypedStore, spotify: SpotifyAPI) {
        self.database = database
        self.settings = settings
        self.spotify = spotify
        reload()
        // База подменяется при восстановлении копии.
        cancellable = database.$generation.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    /// Лайк трека каталога уходит в его аккаунт: `ym_` — в Яндекс Музыку, остальное — в Spotify (при `spotifySyncLikes`).
    private func syncs(_ catalogId: String) -> Bool {
        if YandexIds.isYandex(catalogId) { return !(settings.get(PK.yandexAccessToken) ?? "").isEmpty }
        return !(settings.get(PK.spotifySpDc) ?? "").isEmpty && (settings.get(PK.spotifySyncLikes) ?? true)
    }

    func reload() {
        let ids = (try? database.pool.read { try String.fetchAll($0, sql: "SELECT id FROM song WHERE liked = 1") }) ?? []
        liked = Set(ids)
        checked = []
    }

    func isLiked(_ track: Track) -> Bool { liked.contains(track.id) }

    func toggle(_ track: Track) {
        set(track, liked: !isLiked(track))
    }

    func set(_ track: Track, liked value: Bool) {
        if value { liked.insert(track.id) } else { liked.remove(track.id) }
        let db = database
        DispatchQueue.global(qos: .userInitiated).async {
            try? db.pool.write { d in
                try SongStore.ensure(d, track)
                try d.execute(sql: "UPDATE song SET liked = ?, likedDate = ? WHERE id = ?",
                              arguments: [value ? 1 : 0, value ? SongStore.nowMs() : nil, track.id])
            }
        }
        guard let id = track.catalogId, syncs(id) else { return }
        let api = spotify
        Task {
            do {
                if value { try await api.saveTrack(id) } else { try await api.removeTrack(id) }
            } catch {
                // Spotify не принял — локальный лайк остаётся; следующая сверка покажет расхождение.
            }
        }
    }

    /// Сверяет с аккаунтом Spotify треки, которые ещё не проверялись (сердечко на лайкнутых прямо в Spotify).
    func refresh(_ tracks: [Track]) {
        let fresh = tracks.filter { t in t.catalogId.map(syncs) == true && !checked.contains(t.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { checked.insert($0.id) }
        let api = spotify
        Task { [weak self] in
            guard let flags = try? await api.tracksSaved(fresh.compactMap { $0.catalogId }) else { return }
            await MainActor.run {
                guard let self = self else { return }
                for t in fresh {
                    guard let saved = flags[t.catalogId ?? ""] else { continue }
                    if saved { self.liked.insert(t.id) }
                }
            }
        }
    }

    /// Треки, пришедшие из «Любимых треков» аккаунта, лайкнуты по определению.
    func markLiked(_ ids: [String]) {
        let new = ids.map(FallbackIds.of).filter { !liked.contains($0) }
        if !new.isEmpty { liked.formUnion(new) }
    }
}
