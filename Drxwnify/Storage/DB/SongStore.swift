import Foundation
import GRDB

/// Запись треков и событий прослушивания в `song.db` (таблицы `song`, `artist`, `song_artist_map`, `event`).
/// Время — миллисекунды UTC, как пишет Room на Android.
enum SongStore {
    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Идентификатор артиста без id каталога: стабильный, по имени.
    static func artistId(_ a: Track.Artist) -> String {
        if let id = a.id, !id.isEmpty { return id }
        var h: UInt64 = 1469598103934665603
        for b in a.name.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "LA" + String(h, radix: 36)
    }

    /// Добавляет трек и его артистов, если их ещё нет; существующие строки не трогает.
    static func ensure(_ db: Database, _ t: Track) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO song (id, title, duration, thumbnailUrl, albumId, albumName, explicit, liked, totalPlayTime, isrc)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?)
            """, arguments: [t.id, t.title, t.durationMs / 1000, t.artworkUrl, t.albumId, t.albumName, t.explicit ? 1 : 0, t.isrc])
        for (i, a) in t.artists.enumerated() where !a.name.isEmpty {
            let id = artistId(a)
            try db.execute(sql: "INSERT OR IGNORE INTO artist (id, name, lastUpdateTime, spotifyId) VALUES (?, ?, ?, ?)",
                           arguments: [id, a.name, nowMs(), a.id])
            try db.execute(sql: "INSERT OR IGNORE INTO song_artist_map (songId, artistId, position) VALUES (?, ?, ?)",
                           arguments: [t.id, id, i])
        }
    }

    /// Прослушивание в историю (PLAY-035).
    static func recordPlay(_ database: AppDatabase, track: Track, playTimeMs: Int64) {
        try? database.pool.write { db in
            try ensure(db, track)
            try db.execute(sql: "UPDATE song SET totalPlayTime = totalPlayTime + ? WHERE id = ?", arguments: [playTimeMs, track.id])
            try db.execute(sql: "INSERT INTO event (songId, timestamp, playTime) VALUES (?, ?, ?)",
                           arguments: [track.id, nowMs(), playTimeMs])
        }
    }
}
