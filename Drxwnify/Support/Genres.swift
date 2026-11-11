import SwiftUI
import Foundation

/// Жанры исполнителя и альбома — перенос `portrait/Genres.kt`: теги слушателей Last.fm, затем MusicBrainz;
/// не-жанры («seen live», страны, годы) отбрасываются, написания сводятся. Кэш на диске на месяц
/// (`Application Support/artist_genres.json`, формат как на Android: `{ключ: {"g": [...], "t": ms}}`).
final class Genres: ObservableObject {
    static let shared = Genres()

    /// Ключ Last.fm приложения Drxwnify из Android (`Genres.LASTFM_KEY`, публичный: он в каждом APK).
    private static let androidKey = "710106bd28502d7d62fb5493c67033f9"
    private static var key: String { LastFM.isConfigured ? LastFM.apiKey : androidKey }
    /// Ключ Last.fm для других запросов (похожие артисты, жанровые плейлисты).
    static var apiKey: String { key }

    private static let modifiers: Set<String> = [
        "progressive", "symphonic", "technical", "brutal", "blackened", "melodic", "atmospheric", "modern",
        "epic", "slam", "orchestral", "cinematic", "raw", "old", "school", "old-school", "dissonant", "mathy",
        "experimental", "avant-garde",
    ]

    /// Семья жанра: без ведущих уточнений («progressive metalcore» → «metalcore»), как `Genres.family`.
    static func family(_ tag: String) -> String {
        let words = tag.split(separator: " ").map(String.init)
        var i = 0
        while i < words.count - 1 && modifiers.contains(words[i].lowercased()) { i += 1 }
        return words[i...].joined(separator: " ")
    }
    private static let ttl: Double = 30 * 24 * 3600
    private static let missTtl: Double = 7 * 24 * 3600
    private static let maxTags = 5

    private struct Entry { let genres: [String]; let at: Date }

    @Published private(set) var version = 0
    private var cache: [String: Entry] = [:]
    private var albumCache: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "genres")
    private var lastMusicBrainz = Date.distantPast
    private let lock = NSLock()

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artist_genres.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let o = JSON.object(data) {
            for (k, v) in o {
                guard let e = v as? JSONObject else { continue }
                let g = (e["g"] as? [Any])?.compactMap { $0 as? String } ?? []
                let t = Double(e.int("t") ?? 0) / 1000
                cache[k] = Entry(genres: g, at: Date(timeIntervalSince1970: t))
            }
        }
    }

    private static func keyOf(_ artist: String) -> String { artist.trimmingCharacters(in: .whitespaces).lowercased() }

    func cached(_ artist: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return cache[Self.keyOf(artist)]?.genres ?? []
    }

    private func fresh(_ e: Entry?) -> Bool {
        guard let e = e else { return false }
        return Date().timeIntervalSince(e.at) < (e.genres.isEmpty ? Self.missTtl : Self.ttl)
    }

    /// Жанры исполнителя: из кэша или из сети.
    func of(_ artist: String) async -> [String] {
        let name = artist.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return [] }
        lock.lock(); let e = cache[Self.keyOf(name)]; lock.unlock()
        if fresh(e) { return e?.genres ?? [] }
        let lastFm = await fromLastFm(name)
        let mb = (lastFm?.isEmpty ?? true) ? await fromMusicBrainz(name) : nil
        // Ни один не ответил (нет сети): не запоминаем «без жанров».
        if lastFm == nil && mb == nil { return e?.genres ?? [] }
        let found = (lastFm?.isEmpty == false ? lastFm : mb) ?? []
        lock.lock(); cache[Self.keyOf(name)] = Entry(genres: found, at: Date()); lock.unlock()
        save()
        await MainActor.run { version += 1 }
        return found
    }

    /// Жанры альбома: свои теги Last.fm (если их ≥ 2), иначе вместе с жанрами исполнителя.
    func ofAlbum(artist: String, album: String) async -> [String] {
        let key = Self.keyOf(artist) + "|" + album.lowercased()
        lock.lock(); let e = albumCache[key]; lock.unlock()
        if let e = e, Date().timeIntervalSince(e.at) < Self.ttl { return e.genres }
        let own = await albumFromLastFm(artist, album)
        var genres: [String]
        if let own = own, own.count >= 2 {
            genres = own
        } else {
            genres = own ?? []
            for g in await of(artist) where !genres.contains(g) { genres.append(g) }
            genres = Array(genres.prefix(Self.maxTags))
        }
        if own != nil { lock.lock(); albumCache[key] = Entry(genres: genres, at: Date()); lock.unlock() }
        return genres
    }

    // MARK: - Сеть

    private func get(_ base: String, _ params: [String: String], headers: [String: String] = [:]) async -> JSONObject? {
        var c = URLComponents(string: base)
        c?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url, let r = try? await HTTP.get(url, headers: headers, timeout: 10), r.isSuccess else { return nil }
        return JSON.object(r.data)
    }

    private static func tags(_ list: [JSONObject]) -> [(String, Int)] {
        list.compactMap { o in o.str("name").map { ($0, o.int("count") ?? 0) } }
    }

    private func fromLastFm(_ artist: String) async -> [String]? {
        guard let o = await get("https://ws.audioscrobbler.com/2.0/",
                                ["method": "artist.gettoptags", "artist": artist, "autocorrect": "1", "api_key": Self.key, "format": "json"]) else { return nil }
        return Self.pick(Self.tags(o.obj("toptags")?.objects("tag") ?? []), artist: artist, minCount: 8)
    }

    private func albumFromLastFm(_ artist: String, _ album: String) async -> [String]? {
        var name = album
        if let r = name.range(of: " (") { name = String(name[..<r.lowerBound]) }
        if let r = name.range(of: " [") { name = String(name[..<r.lowerBound]) }
        guard let o = await get("https://ws.audioscrobbler.com/2.0/",
                                ["method": "album.gettoptags", "artist": artist, "album": name.trimmingCharacters(in: .whitespaces),
                                 "autocorrect": "1", "api_key": Self.key, "format": "json"]) else { return nil }
        if o["error"] != nil { return [] }
        return Self.pick(Self.tags(o.obj("toptags")?.objects("tag") ?? []), artist: artist, minCount: 5)
    }

    private func fromMusicBrainz(_ artist: String) async -> [String]? {
        // MusicBrainz просит не чаще раза в секунду.
        let wait = 1.1 - Date().timeIntervalSince(lastMusicBrainz)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastMusicBrainz = Date()
        guard let o = await get("https://musicbrainz.org/ws/2/artist/",
                                ["query": "artist:\"\(artist.replacingOccurrences(of: "\"", with: ""))\"", "limit": "1", "fmt": "json"],
                                headers: ["User-Agent": "Drxwnify/2.0 ( https://drxwnify.pages.dev )"]) else { return nil }
        guard let first = o.objects("artists").first else { return [] }
        if (first.int("score") ?? 0) < 90 { return [] }
        return Self.pick(Self.tags(first.objects("tags")), artist: artist, minCount: 1)
    }

    private func save() {
        lock.lock()
        var o: JSONObject = [:]
        for (k, e) in cache { o[k] = ["g": e.genres, "t": Int64(e.at.timeIntervalSince1970 * 1000)] as JSONObject }
        lock.unlock()
        try? JSON.data(o).write(to: Self.file, options: .atomic)
    }

    // MARK: - Отбор и написание (как в Kotlin)

    static func pick(_ tags: [(String, Int)], artist: String, minCount: Int) -> [String] {
        let own = artist.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [String] = []
        for (name, _) in tags.filter({ $0.1 >= minCount }).sorted(by: { $0.1 > $1.1 }) {
            if let g = normalize(name, artist: own), !out.contains(g) { out.append(g) }
            if out.count >= maxTags { break }
        }
        return out
    }

    private static let notGenres = [
        "seen live", "favorite", "favourite", "vocalist", "female", "male", "love", "awesome", "beautiful",
        "best", "my ", "albums i own", "spotify", "under 2000", "check out", "amazing", "cool", "good",
        "sexy", "cover", "soundtrack of my", "listen", "artist", "band", "singer", "songwriter", "russian",
        "american", "british", "german", "japanese", "french", "swedish", "finnish", "norwegian", "polish",
        "ukrainian", "canadian", "australian", "uk", "usa", "russia", "moscow", "london", "tiktok", "meme",
    ]

    private static let genreWords = [
        "rock", "metal", "pop", "core", "wave", "gaze", "hop", "rap", "jazz", "techno", "house", "trance",
        "step", "bass", "punk", "folk", "soul", "funk", "blues", "ambient", "electro", "drum", "dnb",
        "industrial", "noise", "grunge", "emo", "indie", "alternative", "psych", "prog", "post-", "black",
        "death", "doom", "sludge", "stoner", "thrash", "grind", "garage", "disco", "synth", "idm", "glitch",
        "lo-fi", "lofi", "chill", "trip", "breakbeat", "breaks", "jungle", "footwork", "juke", "dub",
        "reggae", "ska", "r&b", "rnb", "classical", "orchestral", "soundtrack", "chanson", "k-pop",
        "j-pop", "phonk", "drill", "trap", "grime", "hyperpop", "plunderphonics", "vapor", "witch house",
        "minimal", "experimental", "avant", "country", "bluegrass", "latin", "salsa", "cumbia",
        "reggaeton", "afro", "bossa", "slowcore", "math", "screamo", "gothic", "goth", "ebm", "hardstyle",
        "gabber", "hardcore", "shoegaze", "dream", "darkwave", "coldwave", "electronic", "dance", "edm",
        "downtempo", "trip-hop", "acoustic", "singer-songwriter", "new age", "world", "gospel", "opera",
        "neoclassical", "art pop", "bedroom", "cloud rap", "emo rap", "jersey club", "bossa nova",
        "nu jazz", "fusion", "swing", "big band", "chiptune", "8-bit", "vgm", "anime", "city pop",
        "krautrock", "zeuhl", "ethereal", "dark ambient", "drone", "musique concrete", "breakcore",
        "speedcore", "digital hardcore", "witch", "horrorcore", "crunk", "g-funk", "boom bap",
    ]

    private static let aliases: [String: String] = [
        "hip hop": "hip-hop", "hiphop": "hip-hop", "rnb": "r&b", "rhythm and blues": "r&b",
        "drum n bass": "drum and bass", "drum & bass": "drum and bass", "dnb": "drum and bass",
        "drum'n'bass": "drum and bass", "lofi": "lo-fi", "lo fi": "lo-fi", "electronica": "electronic",
        "post rock": "post-rock", "post punk": "post-punk", "post metal": "post-metal",
        "post hardcore": "post-hardcore", "trip hop": "trip-hop", "nu-metal": "nu metal",
        "alt rock": "alternative rock", "alternative": "alternative rock", "dream-pop": "dream pop",
        "synth pop": "synthpop", "synth-pop": "synthpop", "edm": "electronic dance",
        "black-metal": "black metal", "death-metal": "death metal", "witchhouse": "witch house",
        "shoegazer": "shoegaze", "blackgaze": "blackgaze", "rap": "hip-hop",
    ]

    private static let upper: Set<String> = ["idm", "ebm", "edm", "r&b", "uk", "dnb", "vgm", "8-bit"]

    static func normalize(_ raw: String, artist: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if tag.isEmpty || tag == artist || tag.count > 30 { return nil }
        if tag.range(of: #"^\d{2,4}s?$"#, options: .regularExpression) != nil { return nil }
        if notGenres.contains(where: { tag.contains($0) }) { return nil }
        tag = aliases[tag] ?? tag
        if !genreWords.contains(where: { tag.contains($0) }) { return nil }
        return tag.split(separator: " ").map { w -> String in
            let word = String(w)
            if upper.contains(word) { return word.uppercased() }
            return word.split(separator: "-", omittingEmptySubsequences: false).map { p -> String in
                let part = String(p)
                return upper.contains(part) ? part.uppercased() : part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }
}


/// Жанры тегами под шапкой артиста или альбома (Android 2.1.0, 2.1.2).
struct GenreChips: View {
    let artist: String
    var album: String?
    /// По центру в несколько строк (альбом), иначе слева.
    var centered = false
    @State private var genres: [String] = []
    /// Тап по тегу открывает жанровый плейлист (HOME-010).
    @State private var opened: String?

    /// Цвет точки тега — как на Android: постоянный для жанра.
    static func dot(_ genre: String) -> Color {
        let palette: [Color] = [.yellow, .green, .blue, .purple, .pink, .orange, .red,
                                Color(red: 0.2, green: 0.8, blue: 0.8), Color(red: 0.4, green: 0.9, blue: 0.6), Color(red: 0.4, green: 0.6, blue: 1)]
        var h: UInt32 = 5381
        for b in genre.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }

    var body: some View {
        Group {
            if genres.isEmpty {
                Color.clear.frame(height: 0)
            } else {
                FlowChips(items: genres, centered: centered) { g in
                    Button(action: { opened = g }) {
                        HStack(spacing: 6) {
                            Circle().fill(GenreChips.dot(g)).frame(width: 7, height: 7)
                            Text(g).font(.caption.weight(.medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(GenreChips.dot(g).opacity(0.22)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .background(NavigationLink(destination: GenreScreen(genre: opened ?? ""),
                                   isActive: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) { EmptyView() }.opacity(0))
        .onAppear(perform: load)
    }

    private func load() {
        guard genres.isEmpty, !artist.isEmpty else { return }
        let a = artist, al = album
        genres = Genres.shared.cached(a)
        Task {
            let found: [String]
            if let al = al { found = await Genres.shared.ofAlbum(artist: a, album: al) } else { found = await Genres.shared.of(a) }
            await MainActor.run { if !found.isEmpty { genres = found } }
        }
    }
}

/// Теги в несколько строк (на iOS 14 нет `Layout`): раскладка по ширине экрана заранее.
struct FlowChips<Content: View>: View {
    let items: [String]
    var centered = false
    let content: (String) -> Content

    private var rows: [[String]] {
        let maxWidth = UIMetrics.width - 32
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        var rows: [[String]] = [[]]
        var width: CGFloat = 0
        for item in items {
            let w = (item as NSString).size(withAttributes: [.font: font]).width + 20 + 13 + 8
            if width + w > maxWidth, !(rows.last ?? []).isEmpty {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(item)
            width += w
        }
        return rows
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { content($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}
