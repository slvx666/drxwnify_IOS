import Foundation
import Combine
import GRDB

struct LocalPlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    var songCount: Int
    /// Обложки первых треков (для мозаики), если своей обложки нет.
    var thumbnails: [String]
    var thumbnailUrl: String?
    var isEditable: Bool
}

struct PlaylistEntry: Identifiable, Hashable {
    /// `playlist_song_map.id`
    var id: Int64
    var track: Track
}

struct HistoryEntry: Identifiable, Hashable {
    var id: Int64
    var track: Track
    var date: Date
}

struct LocalArtist: Identifiable, Hashable {
    var id: String
    var name: String
    var thumbnailUrl: String?
    var spotifyId: String?
    var songCount: Int
}

struct LocalAlbum: Identifiable, Hashable {
    var id: String
    var title: String
    var thumbnailUrl: String?
    var year: Int?
    var songCount: Int
}

enum SongSort: String, CaseIterable {
    case createDate = "CREATE_DATE", name = "NAME", artist = "ARTIST", playTime = "PLAY_TIME"
}

/// Своя библиотека из `song.db` (этап 8): треки, свои плейлисты, история, топ. Таблицы и поля — как у Room на Android,
/// поэтому восстановленная копия с Android видна сразу.
final class LibraryStore: ObservableObject {
    /// Меняется после каждой записи: экраны перечитывают данные.
    @Published private(set) var revision = 0

    private let database: AppDatabase
    private var cancellable: AnyCancellable?

    init(database: AppDatabase) {
        self.database = database
        cancellable = database.$generation.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.revision += 1 }
        }
    }

    private func changed() {
        DispatchQueue.main.async { self.revision += 1 }
    }

    // MARK: - Чтение треков

    private static let songColumns = "song.id, song.title, song.duration, song.thumbnailUrl, song.albumId, song.albumName, song.explicit, song.isrc"

    private func tracks(_ db: Database, _ rows: [Row]) throws -> [Track] {
        let ids = rows.map { $0["id"] as String }
        var artists: [String: [Track.Artist]] = [:]
        // Артисты одним запросом на пачку (ограничение SQLite на число параметров).
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            start += 500
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let found = try Row.fetchAll(db, sql: """
                SELECT m.songId, a.id, a.name, a.spotifyId FROM song_artist_map m JOIN artist a ON a.id = m.artistId
                WHERE m.songId IN (\(marks)) ORDER BY m.songId, m.position
                """, arguments: StatementArguments(chunk))
            for r in found {
                let spotify: String? = r["spotifyId"]
                let id: String = r["id"]
                let songId: String = r["songId"]
                let name: String = r["name"]
                artists[songId, default: []].append(Track.Artist(id: spotify ?? (id.hasPrefix("LA") ? nil : id), name: name))
            }
        }
        return rows.map { r in
            let id: String = r["id"]
            let seconds: Int = r["duration"]
            return Track(id: id, catalogId: FallbackIds.catalogId(of: id), title: r["title"], artists: artists[id] ?? [],
                         albumId: r["albumId"], albumName: r["albumName"], durationMs: max(0, seconds) * 1000,
                         artworkUrl: r["thumbnailUrl"], explicit: (r["explicit"] as Int) != 0, isrc: r["isrc"])
        }
    }

    private func read<T>(_ fallback: T, _ block: (Database) throws -> T) -> T {
        (try? database.pool.read(block)) ?? fallback
    }

    func likedSongs() -> [Track] {
        read([]) { db in
            try tracks(db, Row.fetchAll(db, sql: "SELECT \(Self.songColumns) FROM song WHERE liked = 1 ORDER BY likedDate DESC, rowid DESC"))
        }
    }

    /// Треки библиотеки: всё, что лайкнуто, добавлено в библиотеку или хоть раз играло.
    func songs(sort: SongSort, descending: Bool) -> [Track] {
        let order: String
        switch sort {
        case .createDate: order = "song.rowid"
        case .name: order = "song.title COLLATE NOCASE"
        case .artist: order = "(SELECT a.name FROM song_artist_map m JOIN artist a ON a.id = m.artistId WHERE m.songId = song.id ORDER BY m.position LIMIT 1) COLLATE NOCASE"
        case .playTime: order = "song.totalPlayTime"
        }
        return read([]) { db in
            try tracks(db, Row.fetchAll(db, sql: """
                SELECT \(Self.songColumns) FROM song
                WHERE liked = 1 OR inLibrary IS NOT NULL OR totalPlayTime > 0 OR id IN (SELECT songId FROM playlist_song_map)
                ORDER BY \(order) \(descending ? "DESC" : "ASC") LIMIT 5000
                """))
        }
    }

    func topSongs(limit: Int = 50) -> [Track] {
        read([]) { db in
            try tracks(db, Row.fetchAll(db, sql: "SELECT \(Self.songColumns) FROM song WHERE totalPlayTime > 0 ORDER BY totalPlayTime DESC LIMIT ?", arguments: [limit]))
        }
    }

    func history(limit: Int = 300) -> [HistoryEntry] {
        read([]) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT event.id AS eventId, event.timestamp, \(Self.songColumns) FROM event JOIN song ON song.id = event.songId
                ORDER BY event.timestamp DESC LIMIT ?
                """, arguments: [limit])
            let list = try tracks(db, rows)
            return zip(rows, list).map { r, t in
                let ms: Int64 = r["timestamp"]
                return HistoryEntry(id: r["eventId"], track: t, date: Date(timeIntervalSince1970: Double(ms) / 1000))
            }
        }
    }

    func removeHistory(_ eventId: Int64) {
        try? database.pool.write { try $0.execute(sql: "DELETE FROM event WHERE id = ?", arguments: [eventId]) }
        changed()
    }

    // MARK: - Артисты и альбомы

    func artists() -> [LocalArtist] {
        read([]) { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.name, a.thumbnailUrl, a.spotifyId,
                       (SELECT COUNT(*) FROM song_artist_map m JOIN song s ON s.id = m.songId
                        WHERE m.artistId = a.id AND (s.liked = 1 OR s.inLibrary IS NOT NULL OR s.totalPlayTime > 0)) AS n
                FROM artist a WHERE a.bookmarkedAt IS NOT NULL OR n > 0 ORDER BY a.name COLLATE NOCASE LIMIT 3000
                """).map { LocalArtist(id: $0["id"], name: $0["name"], thumbnailUrl: $0["thumbnailUrl"], spotifyId: $0["spotifyId"], songCount: $0["n"]) }
        }
    }

    func artistSongs(_ artistId: String) -> [Track] {
        read([]) { db in
            try tracks(db, Row.fetchAll(db, sql: """
                SELECT \(Self.songColumns) FROM song JOIN song_artist_map m ON m.songId = song.id
                WHERE m.artistId = ? ORDER BY song.totalPlayTime DESC, song.title COLLATE NOCASE
                """, arguments: [artistId]))
        }
    }

    func albums() -> [LocalAlbum] {
        read([]) { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, thumbnailUrl, year, songCount FROM album
                WHERE bookmarkedAt IS NOT NULL OR inLibrary IS NOT NULL OR likedDate IS NOT NULL
                ORDER BY COALESCE(bookmarkedAt, likedDate, inLibrary) DESC LIMIT 3000
                """).map { LocalAlbum(id: $0["id"], title: $0["title"], thumbnailUrl: $0["thumbnailUrl"], year: $0["year"], songCount: $0["songCount"]) }
        }
    }

    func albumSongs(_ albumId: String) -> [Track] {
        read([]) { db in
            try tracks(db, Row.fetchAll(db, sql: """
                SELECT \(Self.songColumns) FROM song LEFT JOIN song_album_map m ON m.songId = song.id AND m.albumId = ?
                WHERE song.albumId = ? OR m.albumId = ? ORDER BY COALESCE(m.`index`, 9999), song.rowid
                """, arguments: [albumId, albumId, albumId]))
        }
    }

    // MARK: - Плейлисты

    func playlists() -> [LocalPlaylist] {
        read([]) { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.thumbnailUrl, p.isEditable, (SELECT COUNT(*) FROM playlist_song_map m WHERE m.playlistId = p.id) AS n
                FROM playlist p ORDER BY COALESCE(p.lastUpdateTime, p.createdAt, 0) DESC, p.rowid DESC
                """).map { r in
                let id: String = r["id"]
                let thumbs = try String.fetchAll(db, sql: """
                    SELECT s.thumbnailUrl FROM playlist_song_map m JOIN song s ON s.id = m.songId
                    WHERE m.playlistId = ? AND s.thumbnailUrl IS NOT NULL ORDER BY m.position LIMIT 4
                    """, arguments: [id])
                return LocalPlaylist(id: id, name: r["name"], songCount: r["n"], thumbnails: thumbs, thumbnailUrl: r["thumbnailUrl"],
                                     isEditable: (r["isEditable"] as Int) != 0)
            }
        }
    }

    func playlistEntries(_ playlistId: String) -> [PlaylistEntry] {
        read([]) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS mapId, \(Self.songColumns) FROM playlist_song_map m JOIN song ON song.id = m.songId
                WHERE m.playlistId = ? ORDER BY m.position, m.id
                """, arguments: [playlistId])
            let list = try tracks(db, rows)
            return zip(rows, list).map { PlaylistEntry(id: $0["mapId"], track: $1) }
        }
    }

    /// Идентификатор своего плейлиста — как `PlaylistEntity.generatePlaylistId()` на Android: `LP` + 8 случайных символов.
    private static func newPlaylistId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return "LP" + String((0..<8).map { _ in alphabet.randomElement()! })
    }

    @discardableResult
    func createPlaylist(name: String) -> String {
        let id = Self.newPlaylistId()
        let now = SongStore.nowMs()
        try? database.pool.write {
            try $0.execute(sql: "INSERT INTO playlist (id, name, createdAt, lastUpdateTime, isEditable, bookmarkedAt, isLocal, isAutoSync) VALUES (?, ?, ?, ?, 1, ?, 0, 0)",
                           arguments: [id, name, now, now, now])
        }
        changed()
        return id
    }

    func renamePlaylist(_ id: String, name: String) {
        try? database.pool.write {
            try $0.execute(sql: "UPDATE playlist SET name = ?, lastUpdateTime = ? WHERE id = ?", arguments: [name, SongStore.nowMs(), id])
        }
        changed()
    }

    func deletePlaylist(_ id: String) {
        try? database.pool.write { try $0.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id]) }
        changed()
    }

    /// Какие из треков уже лежат в плейлисте (защита от дублей, LIB-018).
    func contained(in playlistId: String, _ trackIds: [String]) -> Set<String> {
        read([]) { db in
            Set(try String.fetchAll(db, sql: "SELECT songId FROM playlist_song_map WHERE playlistId = ?", arguments: [playlistId]))
        }.intersection(trackIds)
    }

    func add(_ tracks: [Track], to playlistId: String) {
        guard !tracks.isEmpty else { return }
        try? database.pool.write { db in
            var position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_song_map WHERE playlistId = ?", arguments: [playlistId]) ?? 0
            for t in tracks {
                try SongStore.ensure(db, t)
                try db.execute(sql: "INSERT INTO playlist_song_map (playlistId, songId, position) VALUES (?, ?, ?)", arguments: [playlistId, t.id, position])
                position += 1
            }
            try db.execute(sql: "UPDATE playlist SET lastUpdateTime = ? WHERE id = ?", arguments: [SongStore.nowMs(), playlistId])
        }
        changed()
    }

    func remove(entry mapId: Int64, from playlistId: String) {
        try? database.pool.write { db in
            try db.execute(sql: "DELETE FROM playlist_song_map WHERE id = ?", arguments: [mapId])
            try Self.renumber(db, playlistId)
        }
        changed()
    }

    /// Ручной порядок: `order` — идентификаторы строк `playlist_song_map` в новом порядке.
    func reorder(_ playlistId: String, order: [Int64]) {
        try? database.pool.write { db in
            for (i, id) in order.enumerated() {
                try db.execute(sql: "UPDATE playlist_song_map SET position = ? WHERE id = ? AND playlistId = ?", arguments: [i, id, playlistId])
            }
            try db.execute(sql: "UPDATE playlist SET lastUpdateTime = ? WHERE id = ?", arguments: [SongStore.nowMs(), playlistId])
        }
        changed()
    }

    private static func renumber(_ db: Database, _ playlistId: String) throws {
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM playlist_song_map WHERE playlistId = ? ORDER BY position, id", arguments: [playlistId])
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE playlist_song_map SET position = ? WHERE id = ?", arguments: [i, id])
        }
    }

    // MARK: - Сводка

    struct Summary {
        var liked = 0
        var songs = 0
        var playlists = 0
        var history = 0
    }

    func summary() -> Summary {
        read(Summary()) { db in
            Summary(liked: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? 0,
                    songs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song") ?? 0,
                    playlists: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0,
                    history: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0)
        }
    }
}
