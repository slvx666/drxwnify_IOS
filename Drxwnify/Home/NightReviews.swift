import Foundation

/// Альбомы, которые drxwnslvt разбирает в Telegram-канале, как их перечисляет сайт канала (`reviews/NightReviews.kt`).
/// Берутся только факты — артист, альбом, год, оценка, жанры, дата; альбом ищется в каталоге приложения.
actor NightReviews {
    struct Review: Hashable {
        var id: String
        var artist: String
        var album: String
        var year: Int?
        var rating: Double
        var genres: [String]
        /// Без влияний: собственные жанры альбома.
        var mainGenres: [String]
    }

    static let shared = NightReviews()
    private static let base = "https://tgzip.drxwnslvt.workers.dev/"
    private static let dataURL = base + "data/reviews.json"
    private static let liveURL = base + "api/live"

    private var reviews: [Review] = []
    private var asked = false
    private let defaults = UserDefaults(suiteName: "night_reviews") ?? .standard

    private static var cacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("night_reviews.json")
    }

    /// Список без ожидания сайта (он открывается не везде без VPN): загруженный, иначе последний скачанный,
    /// иначе снимок, вшитый в приложение.
    func offline() -> [Review] {
        if !reviews.isEmpty { return reviews }
        if let data = try? Data(contentsOf: Self.cacheFile), let list = Self.parse(data), !list.isEmpty { reviews = list; return list }
        if let url = Bundle.main.url(forResource: "night_reviews_snapshot", withExtension: "json"),
           let data = try? Data(contentsOf: url), let list = Self.parse(data) { return list }
        return []
    }

    /// Спрашивает сайт один раз за запуск (за страницей, ничего не ждёт).
    func refreshOnce() async {
        if asked { return }
        asked = true
        guard let built = await Self.fetch(Self.dataURL) else { return }
        var text = built
        if let live = await Self.fetch(Self.liveURL), let merged = Self.mergeLive(built, live) { text = merged }
        guard let list = Self.parse(text), !list.isEmpty else { return }
        try? text.write(to: Self.cacheFile, options: .atomic)
        reviews = list
    }

    private static func fetch(_ url: String) async -> Data? {
        guard let u = URL(string: url + "?t=\(Int(Date().timeIntervalSince1970 * 1000))"),
              let r = try? await HTTP.get(u, headers: ["Cache-Control": "no-cache"], timeout: 20), r.isSuccess else { return nil }
        return r.data
    }

    /// Свежие посты бота поверх сборки сайта (как `mergeLive` сайта): живой пост заменяет собранный, новый добавляется.
    private static func mergeLive(_ built: Data, _ live: Data) -> Data? {
        guard var base = JSON.object(built), let liveList = JSON.object(live)?.objects("reviews") else { return nil }
        let exported = Int64(base.int("exportedTs") ?? 0)
        var list = base.objects("reviews")
        var indexById: [String: Int] = [:]
        for (i, o) in list.enumerated() { if let id = o.str("id") { indexById[id] = i } }
        let kept = ["c", "l", "pop", "img", "pal", "mg", "ls", "pc", "tn", "dur"]
        for l in liveList {
            if exported > 0 && Int64(l.int("ed") ?? 0) <= exported { continue }
            let id = l.str("id") ?? ""
            if let at = indexById[id] {
                let old = list[at]
                var merged = l
                for k in kept { if let v = old[k], !(v is NSNull), "\(v)" != "", "\(v)" != "0" { merged[k] = v } }
                list[at] = merged
            } else {
                list.append(l)
                indexById[id] = list.count - 1
            }
        }
        base["reviews"] = list
        return JSON.data(base)
    }

    private static func parse(_ data: Data) -> [Review]? {
        guard let root = JSON.object(data) else { return nil }
        return root.objects("reviews").compactMap { o in
            let artist = (o.str("ar") ?? "").trimmingCharacters(in: .whitespaces)
            let album = (o.str("al") ?? "").trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty, !album.isEmpty else { return nil }
            let genres = (o.arr("g") ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            let influence = (o.arr("gi") ?? []).map { ($0 as? Bool) ?? false }
            let main = genres.enumerated().filter { $0.offset >= influence.count || !influence[$0.offset] }.map { $0.element }
            let rating = (o["r"] as? NSNumber)?.doubleValue ?? 0
            let year = o.int("y").flatMap { $0 > 0 ? $0 : nil }
            return Review(id: (o.str("id") ?? "").isEmpty ? "\(artist)|\(album)" : o.str("id")!, artist: artist, album: album,
                          year: year, rating: rating, genres: genres, mainGenres: main)
        }
    }

    /// Альбом каталога по артисту и названию; найденный id запоминается.
    func findAlbum(_ review: Review, api: SpotifyAPI) async -> String? {
        let key = "album:\(MainAccount.shared.main?.rawValue ?? "SPOTIFY"):\(review.id)"
        if let id = defaults.string(forKey: key) { return id }
        let wantedTitle = Self.normalize(review.album)
        let wantedArtist = Self.normalize(review.artist)
        for query in ["\(review.artist) \(review.album)", review.album] {
            guard let r = try? await api.search(query, limit: 20) else { continue }
            let scored = r.albums.map { album -> (SpotifyAlbum, Int, Bool) in
                let title = Self.normalize(album.name)
                let artistOk = album.artists.contains { a in
                    let n = Self.normalize(a.name)
                    return n == wantedArtist || n.contains(wantedArtist) || wantedArtist.contains(n)
                }
                let titleScore: Int
                if title == wantedTitle { titleScore = 3 } else if title.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(title) { titleScore = 2 } else if title.contains(wantedTitle) || wantedTitle.contains(title) { titleScore = 1 } else { titleScore = 0 }
                let yearOk = review.year == nil || album.year.flatMap(Int.init) == review.year
                return (album, artistOk ? titleScore : 0, yearOk)
            }.filter { $0.1 > 0 }
            let best = scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : (a.2 && !b.2) }.first?.0
            if let best = best, !best.id.isEmpty {
                defaults.set(best.id, forKey: key)
                return best.id
            }
        }
        return nil
    }

    /// Нижний регистр, без диакритики и пометок «deluxe»/«remaster», пунктуация — пробелы.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"[(\[].*?(deluxe|remaster|edition|version|expanded)[^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
