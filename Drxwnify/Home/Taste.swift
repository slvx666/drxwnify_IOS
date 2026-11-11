import Foundation
import GRDB

/// Сырые данные о вкусе слушателя из `song.db` и аккаунта каталога — общий источник для «Для тебя», рядов главной
/// и главной новичка (на Android это читают `ForYouRecommender`, `HomeFeed` и `HomeViewModel` каждый сам).
struct TasteData {
    struct Play {
        var songId: String
        var title: String
        var album: String?
        var artist: String
        var artistId: String?
        var ageDays: Double
        var playTimeMs: Int64
        var durationMs: Int64
    }

    struct Named {
        var title: String
        var artist: String
        var artistId: String?
    }

    /// Последние прослушивания (новые первыми), до 5000.
    var plays: [Play] = []
    /// Всего прослушиваний в истории.
    var playCount = 0
    /// Свои лайки, новые первыми.
    var liked: [Named] = []
    /// Подписки на артистов в приложении: имя и каталожный id.
    var followed: [(name: String, id: String?)] = []
    /// Лайки и подписки в аккаунте каталога (Spotify или Яндекс).
    var account = AccountLikes.Snapshot()

    static func load(database: AppDatabase, spotify: SpotifyAPI) async -> TasteData {
        var data = local(database)
        data.account = await AccountLikes.shared.get(spotify)
        return data
    }

    /// Только база (синхронно, вне главного потока).
    static func local(_ database: AppDatabase) -> TasteData {
        var data = TasteData()
        let nowMs = Double(SongStore.nowMs())
        try? database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.songId, e.timestamp, e.playTime, s.title, s.albumName, s.duration, a.name AS artistName, a.id AS artistId, a.spotifyId
                FROM event e JOIN song s ON s.id = e.songId
                LEFT JOIN song_artist_map m ON m.songId = s.id AND m.position = 0
                LEFT JOIN artist a ON a.id = m.artistId
                ORDER BY e.timestamp DESC LIMIT 5000
                """)
            data.plays = rows.compactMap { r -> Play? in
                guard let artist: String = r["artistName"], !artist.isEmpty else { return nil }
                let ts: Int64 = r["timestamp"] ?? 0
                let spotifyId: String? = r["spotifyId"]
                let rawId: String? = r["artistId"]
                return Play(songId: r["songId"] ?? "", title: r["title"] ?? "", album: r["albumName"], artist: artist,
                            artistId: RadioKeys.catalogArtistId(spotifyId) ?? RadioKeys.catalogArtistId(rawId),
                            ageDays: max(0, (nowMs - Double(ts)) / 86_400_000), playTimeMs: r["playTime"] ?? 0,
                            durationMs: (r["duration"] as Int64? ?? 0) * 1000)
            }
            data.playCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let liked = try Row.fetchAll(db, sql: """
                SELECT s.title, a.name AS artistName, a.id AS artistId, a.spotifyId FROM song s
                LEFT JOIN song_artist_map m ON m.songId = s.id AND m.position = 0
                LEFT JOIN artist a ON a.id = m.artistId
                WHERE s.liked = 1 ORDER BY s.likedDate DESC
                """)
            data.liked = liked.compactMap { r -> Named? in
                guard let artist: String = r["artistName"], !artist.isEmpty else { return nil }
                let spotifyId: String? = r["spotifyId"]
                let rawId: String? = r["artistId"]
                return Named(title: r["title"] ?? "", artist: artist,
                             artistId: RadioKeys.catalogArtistId(spotifyId) ?? RadioKeys.catalogArtistId(rawId))
            }
            let followed = try Row.fetchAll(db, sql: "SELECT name, id, spotifyId FROM artist WHERE bookmarkedAt IS NOT NULL ORDER BY bookmarkedAt DESC")
            data.followed = followed.compactMap { r -> (name: String, id: String?)? in
                guard let name: String = r["name"], !name.isEmpty else { return nil }
                let spotifyId: String? = r["spotifyId"]
                let rawId: String? = r["id"]
                return (name, RadioKeys.catalogArtistId(spotifyId) ?? RadioKeys.catalogArtistId(rawId))
            }
        }
        return data
    }

    /// Засчитано ли прослушивание (`Listening.counts`): половина трека, от 30 с до 4 мин.
    static func counts(playedMs: Int64, durationMs: Int64) -> Bool {
        let floor: Int64 = 30_000
        let needed: Int64
        if durationMs <= 0 { needed = 60_000 } else if durationMs < floor { needed = durationMs * 9 / 10 } else { needed = min(max(durationMs / 2, floor), 240_000) }
        return playedMs >= needed
    }
}

/// Лайки и подписки в аккаунте каталога (`catalog/AccountLikes.kt` + `LikedSongsCache`): держатся 6 часов на диске,
/// чтобы главная не ждала сеть.
actor AccountLikes {
    struct Snapshot: Codable {
        var tracks: [SpotifyTrack] = []
        /// id трека → когда лайкнут (мс).
        var addedAt: [String: Int64] = [:]
        var artists: [String] = []
        var artistIds: [String: String] = [:]
        var at: Double = 0
        var account = ""
    }

    static let shared = AccountLikes()
    private static let ttl: Double = 6 * 3600
    private var memory: Snapshot?
    private var running: Task<Snapshot, Never>?

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("account_likes.json")
    }

    private func accountKey(_ api: SpotifyAPI) -> String {
        if api.yandexIsSource { return "yandex" }
        return (api.settings?.get(PK.spotifySpDc) ?? "").isEmpty ? "" : "spotify"
    }

    /// Последнее известное без сети.
    func lastKnown() -> Snapshot {
        if let m = memory { return m }
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Snapshot.self, from: data) { memory = s; return s }
        return Snapshot()
    }

    func get(_ api: SpotifyAPI, force: Bool = false) async -> Snapshot {
        let key = accountKey(api)
        if key.isEmpty { return Snapshot() }
        let known = lastKnown()
        if !force, known.account == key, Date().timeIntervalSince1970 - known.at < Self.ttl { return known }
        if let r = running { return await r.value }
        let task = Task { () -> Snapshot in
            var s = Snapshot(account: key)
            s.at = Date().timeIntervalSince1970
            var offset = 0
            let iso = ISO8601DateFormatter()
            while offset < 2000 {
                guard let page = try? await api.likedSongs(limit: 50, offset: offset) else { break }
                for item in page.items where !item.track.id.isEmpty {
                    s.tracks.append(item.track)
                    if let a = item.addedAt, let d = iso.date(from: a) { s.addedAt[item.track.id] = Int64(d.timeIntervalSince1970 * 1000) }
                }
                offset += 50
                if page.items.isEmpty || offset >= page.total { break }
            }
            if let artists = try? await api.myLibraryAll(filter: "Artists") {
                for a in artists where a.kind == .artist {
                    s.artists.append(a.name)
                    s.artistIds[a.name.lowercased()] = a.id
                }
            }
            // Ничего не пришло (нет сети): лучше старое.
            if s.tracks.isEmpty && s.artists.isEmpty && known.account == key { return known }
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.file, options: .atomic) }
            return s
        }
        running = task
        let s = await task.value
        running = nil
        memory = s
        return s
    }
}
