import Foundation
import GRDB

struct LyricLine: Hashable, Identifiable {
    var id: Int
    /// Секунды от начала; nil — текст без разметки по времени.
    var time: Double?
    var text: String
}

struct Lyrics {
    static let notFound = "LYRICS_NOT_FOUND"

    var raw: String
    var provider: String
    var lines: [LyricLine]

    var isSynced: Bool { lines.contains { $0.time != nil } }

    init(raw: String, provider: String) {
        self.raw = raw
        self.provider = provider
        self.lines = Lyrics.parse(raw)
    }

    /// Разбор LRC: `[mm:ss.xx] строка`, несколько меток на строку; без меток — обычный текст.
    static func parse(_ raw: String) -> [LyricLine] {
        guard let re = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]") else { return [] }
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                // Служебные теги LRC ([ar:], [ti:], [offset:]) в текст не идут.
                if line.hasPrefix("[") && line.contains(":") && line.hasSuffix("]") { continue }
                plain.append(line)
                continue
            }
            let text = ns.substring(from: matches.last!.range.upperBound).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    fraction = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                timed.append((minutes * 60 + seconds + fraction, text))
            }
        }
        if !timed.isEmpty {
            return timed.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        }
        return plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }
}

/// Тексты песен: кэш в таблице `lyrics` (как на Android) и поиск в LRCLIB.
final class LyricsStore {
    private let database: AppDatabase
    private static let ua = "Drxwnify (https://drxwnify.pages.dev)"

    init(database: AppDatabase) {
        self.database = database
    }

    func cached(_ id: String) -> Lyrics? {
        guard let row = try? database.pool.read({ try Row.fetchOne($0, sql: "SELECT lyrics, provider FROM lyrics WHERE id = ?", arguments: [id]) }) else { return nil }
        let text: String = row["lyrics"]
        if text == Lyrics.notFound || text.isEmpty { return nil }
        return Lyrics(raw: text, provider: row["provider"])
    }

    private func save(_ track: Track, _ text: String, provider: String) {
        try? database.pool.write { db in
            try SongStore.ensure(db, track)
            try db.execute(sql: "INSERT OR REPLACE INTO lyrics (id, lyrics, provider) VALUES (?, ?, ?)", arguments: [track.id, text, provider])
        }
    }

    func clear(_ id: String) {
        try? database.pool.write { try $0.execute(sql: "DELETE FROM lyrics WHERE id = ?", arguments: [id]) }
    }

    /// Текст для трека: из кэша, иначе из сети. nil — не найден.
    func lyrics(for track: Track, refresh: Bool = false) async -> Lyrics? {
        if !refresh, let hit = cached(track.id) { return hit }
        if let found = await fetchLrcLib(track) {
            save(track, found.raw, provider: found.provider)
            return found
        }
        return nil
    }

    private func fetchLrcLib(_ t: Track) async -> Lyrics? {
        let title = FuzzyTrackMatch.titleVariants(t.title).last ?? t.title
        let artist = t.artists.first?.name ?? ""
        func pick(_ o: JSONObject) -> Lyrics? {
            if let s = o.str("syncedLyrics"), !s.isEmpty { return Lyrics(raw: s, provider: "LrcLib") }
            if let p = o.str("plainLyrics"), !p.isEmpty { return Lyrics(raw: p, provider: "LrcLib") }
            return nil
        }
        // Точное совпадение по названию, артисту и длине.
        var c = URLComponents(string: "https://lrclib.net/api/get")
        var items = [URLQueryItem(name: "track_name", value: t.title), URLQueryItem(name: "artist_name", value: artist)]
        if let album = t.albumName, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if t.durationMs > 0 { items.append(URLQueryItem(name: "duration", value: String(t.durationMs / 1000))) }
        c?.queryItems = items
        if let url = c?.url, let r = try? await HTTP.get(url, headers: ["User-Agent": Self.ua], timeout: 10), r.isSuccess,
           let o = JSON.object(r.data), let l = pick(o) {
            return l
        }
        // Поиск: ближайший по длине, с разметкой по времени в приоритете.
        var s = URLComponents(string: "https://lrclib.net/api/search")
        s?.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = s?.url, let r = try? await HTTP.get(url, headers: ["User-Agent": Self.ua], timeout: 10), r.isSuccess,
              let list = JSON.array(r.data) as? [JSONObject] else { return nil }
        let wanted = Double(t.durationMs) / 1000
        let close = list.filter { o in
            guard wanted > 0, let d = o.double("duration") else { return true }
            return abs(d - wanted) <= 5
        }
        let synced = close.first { !($0.str("syncedLyrics") ?? "").isEmpty }
        return (synced ?? close.first).flatMap(pick)
    }
}
