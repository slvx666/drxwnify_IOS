import Foundation
import GRDB

struct LyricWord: Hashable {
    var time: Double
    var text: String
}

struct LyricLine: Hashable, Identifiable {
    var id: Int
    /// Секунды от начала; nil — текст без разметки по времени.
    var time: Double?
    var text: String
    /// Пословная разметка (`<mm:ss.xx>` перед словом), если есть (LYR-002).
    var words: [LyricWord] = []
    /// Фоновый голос (`{bg}`): мельче и тусклее.
    var background = false
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
        let wordRe = try? NSRegularExpression(pattern: "<(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?>")
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
            return timed.sorted { $0.0 < $1.0 }.enumerated().map { i, item in
                var (text, background) = stripMarks(item.1)
                var words: [LyricWord] = []
                if let re = wordRe, text.contains("<") {
                    let ns = text as NSString
                    let ms = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
                    for (k, m) in ms.enumerated() {
                        let end = k + 1 < ms.count ? ms[k + 1].range.location : ns.length
                        let chunk = ns.substring(with: NSRange(location: m.range.upperBound, length: end - m.range.upperBound))
                        words.append(LyricWord(time: seconds(ns, m), text: chunk))
                    }
                    text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                }
                return LyricLine(id: i, time: item.0, text: text.trimmingCharacters(in: .whitespaces), words: words, background: background)
            }
        }
        return plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: stripMarks($0.element).0) }
    }

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> Double {
        let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
        var fraction = 0.0
        if m.range(at: 3).location != NSNotFound {
            let f = ns.substring(with: m.range(at: 3))
            fraction = (Double(f) ?? 0) / pow(10, Double(f.count))
        }
        return minutes * 60 + secs + fraction
    }

    /// Убирает пометки исполнителей (`{agent:v1}`, `v1:`) и фона (`{bg}`).
    private static func stripMarks(_ line: String) -> (String, Bool) {
        var t = line
        var background = false
        while true {
            let before = t
            if t.hasPrefix("{bg}") { background = true; t.removeFirst(4) }
            for p in [#"^\{agent:[^}]+\}"#, #"^v\d+:"#] {
                if let r = t.range(of: p, options: .regularExpression) { t.removeSubrange(r) }
            }
            t = t.trimmingCharacters(in: .whitespaces)
            if t == before { break }
        }
        return (t, background)
    }
}

/// Тексты песен: кэш в таблице `lyrics` (как на Android) и поиск в LRCLIB.
final class LyricsStore {
    private let database: AppDatabase
    private static let ua = "Drxwnify (https://drxwnify.pages.dev)"
    /// Порядок и включение источников (ставит `AppEnvironment`).
    var settings: TypedStore?
    /// На все источники вместе — 30 с, каждому поровну (`LyricsHelper.MAX_LYRICS_FETCH_MS`).
    private static let maxFetch: Double = 30

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

    /// Сдвиг синхронизации трека в мс (`song.lyricsOffset`, LYR-008).
    func offset(_ id: String) -> Int {
        (try? database.pool.read { try Int.fetchOne($0, sql: "SELECT lyricsOffset FROM song WHERE id = ?", arguments: [id]) } ?? 0) ?? 0
    }

    func setOffset(_ track: Track, _ ms: Int) {
        try? database.pool.write { db in
            try SongStore.ensure(db, track)
            try db.execute(sql: "UPDATE song SET lyricsOffset = ? WHERE id = ?", arguments: [ms, track.id])
        }
    }

    /// Текст для трека: из кэша, иначе источники по порядку из настроек (первый ответ побеждает, как `LyricsHelper`).
    func lyrics(for track: Track, refresh: Bool = false) async -> Lyrics? {
        if !refresh, let hit = cached(track.id) { return hit }
        guard let settings = settings else { return await legacy(track) }
        let names = LyricsProviders.order(settings).filter { LyricsProviders.isEnabled($0, settings) }
        let per = Self.maxFetch / Double(max(1, names.count))
        for name in names {
            guard let text = await Self.withTimeout(per, { await self.fetch(name, track) }), !text.isEmpty else { continue }
            let l = Lyrics(raw: LyricsProviders.filterCredits(text), provider: name)
            if l.lines.isEmpty { continue }
            save(track, l.raw, provider: name)
            return l
        }
        return nil
    }

    private func fetch(_ name: String, _ t: Track) async -> String? {
        let title = LyricsProviders.cleanTitle(t.title)
        let artist = t.artistNames
        let sec = t.durationMs / 1000
        switch name {
        case "BetterLyrics": return await LyricsProviders.betterLyrics(title: t.title, artist: artist, durationSec: sec, album: t.albumName)
        case "Paxsenix": return await LyricsProviders.paxsenix(title: title, artist: artist, durationSec: sec, album: t.albumName)
        case "LrcLib": return await fetchLrcLib(t)?.raw
        case "KuGou": return await KuGouLyrics.fetch(t)
        case "LyricsPlus": return await LyricsProviders.lyricsPlus(title: title, artist: artist, durationMs: t.durationMs, album: t.albumName)
        default: return nil
        }
    }

    private static func withTimeout(_ seconds: Double, _ work: @escaping () async -> String?) async -> String? {
        await withTaskGroup(of: String??.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Без настроек: LrcLib, затем KuGou.
    private func legacy(_ track: Track) async -> Lyrics? {
        let lrc = await fetchLrcLib(track)
        // Синхронный текст LrcLib — сразу; иначе пробуем KuGou (как `LyricsProviderRegistry` на Android), обычный текст — запасной.
        if let l = lrc, l.isSynced {
            save(track, l.raw, provider: l.provider)
            return l
        }
        if let k = await KuGouLyrics.fetch(track) {
            save(track, k, provider: "KuGou")
            return Lyrics(raw: k, provider: "KuGou")
        }
        if let l = lrc {
            save(track, l.raw, provider: l.provider)
            return l
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

/// KuGou — перенос `kugou/.../KuGou.kt`: поиск песни, текст по hash или по ключевым словам, LRC в base64.
enum KuGouLyrics {
    private static let durationTolerance = 8

    static func fetch(_ t: Track) async -> String? {
        let title = normalizeTitle(t.title)
        let artist = normalizeArtist(t.artistNames)
        let keyword = "\(title) - \(artist)"
        let duration = t.durationMs > 0 ? t.durationMs / 1000 : -1
        if let songs = await json("https://mobileservice.kugou.com/api/v3/search/song",
                                  ["version": "9108", "plat": "0", "pagesize": "8", "showtype": "0", "keyword": keyword]) {
            for song in songs.obj("data")?.objects("info") ?? [] {
                let d = song.int("duration") ?? 0
                guard duration == -1 || abs(d - duration) <= durationTolerance, let hash = song.str("hash") else { continue }
                if let c = await json("https://lyrics.kugou.com/search", ["ver": "1", "man": "yes", "client": "pc", "hash": hash])?.objects("candidates").first,
                   let text = await download(c) {
                    return text
                }
            }
        }
        var params = ["ver": "1", "man": "yes", "client": "pc", "keyword": keyword]
        if duration > 0 { params["duration"] = String(duration * 1000) }
        guard let c = await json("https://lyrics.kugou.com/search", params)?.objects("candidates").first else { return nil }
        return await download(c)
    }

    private static func download(_ c: JSONObject) async -> String? {
        guard let id = c.str("id"), let key = c.str("accesskey"),
              let o = await json("https://lyrics.kugou.com/download", ["fmt": "lrc", "charset": "utf8", "client": "pc", "ver": "1", "id": id, "accesskey": key]),
              let b64 = o.str("content"), let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else { return nil }
        let out = normalize(text)
        return out.isEmpty ? nil : out
    }

    private static func json(_ base: String, _ params: [String: String]) async -> JSONObject? {
        var c = URLComponents(string: base)
        c?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url, let r = try? await HTTP.get(url, headers: [:], timeout: 8), r.isSuccess else { return nil }
        return JSON.object(r.data)
    }

    private static func strip(_ s: String, _ patterns: [String]) -> String {
        patterns.reduce(s) { $0.replacingOccurrences(of: $1, with: "", options: .regularExpression) }
    }

    static func normalizeTitle(_ t: String) -> String {
        strip(t, [#"\(.*\)"#, "（.*）", "「.*」", "『.*』", "<.*>", "《.*》", "〈.*〉", "＜.*＞"]).trimmingCharacters(in: .whitespaces)
    }

    static func normalizeArtist(_ a: String) -> String {
        let s = a.replacingOccurrences(of: ", ", with: "、").replacingOccurrences(of: " & ", with: "、")
            .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "和", with: "、")
        return strip(s, [#"\(.*\)"#, "（.*）"]).trimmingCharacters(in: .whitespaces)
    }

    /// Только строки с разметкой времени; шапка и хвост с «автор: …» отрезаются (как `normalize()` в Kotlin).
    static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter {
            $0.range(of: #"^\[(\d\d):(\d\d)\.(\d{2,3})\].*"#, options: .regularExpression) != nil
        }
        guard !lines.isEmpty else { return "" }
        func banned(_ l: String) -> Bool { l.range(of: #".+\].+[:：].+"#, options: .regularExpression) != nil }
        var head = 0
        for i in stride(from: min(30, lines.count - 1), through: 0, by: -1) where banned(lines[i]) { head = i + 1; break }
        let filtered = Array(lines.dropFirst(head))
        var tail = 0
        let upper = min(lines.count - 30, lines.count - 1)
        if upper >= 0 {
            for i in stride(from: upper, through: 0, by: -1) where banned(lines[lines.count - 1 - i]) { tail = i + 1; break }
        }
        return filtered.dropLast(min(tail, filtered.count)).joined(separator: "\n")
    }
}

