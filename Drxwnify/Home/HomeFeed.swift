import Foundation

/// Ряд треков артистов, близких к любимым: «Рядом с <артистом>» (`genre == nil`) или «Похожее в <жанре>».
struct SimilarRow: Codable, Hashable {
    var artist: String
    var artistId: String?
    var image: String?
    var tracks: [SpotifyTrack] = []
    var genre: String?
}

/// Личная часть главной (`home/HomeFeed.kt`, HOME-004): из того, что слушатель любит, на что подписан и что слушает.
struct HomeFeedData: Codable {
    var builtAt: Double = 0
    var format = 0
    var newReleases: [SpotifyAlbum] = []
    var similar: [SimilarRow] = []
    var genreRows: [SimilarRow] = []
    var genres: [String] = []
    var forgotten: [SpotifyTrack] = []
    var deepCuts: [SpotifyTrack] = []
    var unheardAlbums: [SpotifyAlbum] = []
    var favoriteArtists: [String] = []
}

/// Строит личные ряды главной и держит их на диске: главная сразу показывает прошлые, новые собираются за ней,
/// если старым больше 6 часов (или по жесту «обновить»). Каждый ряд публикуется, как только готов.
///
/// «Любимый» — любимый, а не просто прослушанный: лайки, подписки и треки, что слушают снова и снова;
/// простые прослушивания только разбивают ничьи.
final class HomeFeed: ObservableObject {
    static let shared = HomeFeed()

    private static let ttl: Double = 6 * 3600
    private static let forgottenAfterDays: Double = 60
    static let format = 4
    private static let minLove = 1.0

    @Published private(set) var feed: HomeFeedData?
    private var building = false

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("home_feed.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), var saved = try? JSONDecoder().decode(HomeFeedData.self, from: data) {
            if saved.format != Self.format { saved.similar = []; saved.genreRows = [] }
            feed = saved
        }
    }

    @MainActor
    func refresh(_ data: TasteData, api: SpotifyAPI, hideExplicit: Bool, force: Bool = false) async {
        let fresh = feed.map { $0.format == Self.format && Date().timeIntervalSince1970 - $0.builtAt < Self.ttl } ?? false
        if (!force && fresh) || building { return }
        building = true
        defer { building = false }
        // День выбирает ряды; «обновить» выбирает заново.
        let rotation: UInt64 = force ? UInt64.random(in: 0...UInt64.max) : UInt64(Date().timeIntervalSince1970 / 86400)
        await build(data, api: api, hideExplicit: hideExplicit, rotation: rotation)
    }

    struct Favorite { var name: String; var id: String?; var score: Double }

    final class Taste {
        var favorites: [Favorite] = []
        var known = Set<String>()
        var knownArtists = Set<String>()
        var recentlyHeard = Set<String>()
        var albumTracks: [String: Set<String>] = [:]
        var likedTracks: [SpotifyTrack] = []
        var likedAt: [String: Int64] = [:]
        var likesByArtist: [String: Int] = [:]
        var playsByArtist: [String: Double] = [:]
    }

    @MainActor
    private func build(_ data: TasteData, api: SpotifyAPI, hideExplicit: Bool, rotation: UInt64) async {
        let taste = Self.taste(data)
        let favorites = await Self.resolveIds(taste.favorites, api: api)
        if feed == nil { feed = HomeFeedData() }
        feed?.favoriteArtists = favorites.map { $0.name }

        async let stats = Self.genreStats(taste)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let r = await Self.unheardAlbums(favorites, taste, rotation, api)
                await MainActor.run { self.feed?.unheardAlbums = r }
            }
            group.addTask {
                let r = await Self.deepCuts(favorites, taste, hideExplicit, rotation, api)
                await MainActor.run { self.feed?.deepCuts = r }
            }
            group.addTask {
                let r = await Self.similar(favorites, taste, hideExplicit, rotation, api)
                await MainActor.run { self.feed?.similar = r }
            }
            group.addTask {
                let r = Self.forgotten(taste, hideExplicit, rotation)
                await MainActor.run { self.feed?.forgotten = r }
            }
        }
        let s = await stats
        feed?.genres = s.top
        feed?.genreRows = await Self.genreRows(s, favorites, taste, hideExplicit, rotation, api)
        feed?.builtAt = Date().timeIntervalSince1970
        feed?.format = Self.format
        if let f = feed, let out = try? JSONEncoder().encode(f) { try? out.write(to: Self.file, options: .atomic) }
    }

    // MARK: - Вкус

    static func taste(_ data: TasteData) -> Taste {
        let t = Taste()
        var love: [String: Double] = [:]
        var names: [String: String] = [:]
        var ids: [String: String] = [:]
        func note(_ name: String, _ id: String?) -> String? {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            let key = n.lowercased()
            if names[key] == nil { names[key] = n }
            if let id = id, ids[key] == nil { ids[key] = id }
            t.knownArtists.insert(key)
            return key
        }
        var chosenPerTrack: [String: Int] = [:]
        var artistOfTrack: [String: String] = [:]
        for p in data.plays {
            guard let key = note(p.artist, p.artistId) else { continue }
            let trackKey = RadioKeys.trackKey(p.artist, p.title)
            t.known.insert(trackKey)
            if p.ageDays <= forgottenAfterDays { t.recentlyHeard.insert(trackKey) }
            if let album = p.album, !album.isEmpty {
                t.albumTracks[RadioKeys.albumKey(p.artist, album), default: []].insert(trackKey)
            }
            if p.ageDays > 240 || !TasteData.counts(playedMs: p.playTimeMs, durationMs: p.durationMs) { continue }
            t.playsByArtist[key, default: 0] += exp(-p.ageDays / 90.0)
            chosenPerTrack[trackKey, default: 0] += 1
            artistOfTrack[trackKey] = key
        }
        // Слушал снова и снова — тоже любовь, чуть меньше лайка; с потолком на артиста.
        var repeats: [String: Double] = [:]
        for (track, n) in chosenPerTrack where n >= 3 {
            if let a = artistOfTrack[track] { repeats[a, default: 0] += 0.6 }
        }
        for (key, r) in repeats { love[key, default: 0] += min(1.2, r) }
        // Простые прослушивания только разбивают ничьи.
        for (key, p) in t.playsByArtist { love[key, default: 0] += min(0.5, p * 0.02) }

        t.likedTracks = data.account.tracks
        t.likedAt = data.account.addedAt
        for tr in data.account.tracks {
            guard let a = tr.artists.first, let key = note(a.name, RadioKeys.catalogArtistId(a.id) ?? a.id) else { continue }
            t.known.insert(RadioKeys.trackKey(a.name, tr.name))
            love[key, default: 0] += 1
            t.likesByArtist[key, default: 0] += 1
        }
        for l in data.liked {
            guard let key = note(l.artist, l.artistId) else { continue }
            t.known.insert(RadioKeys.trackKey(l.artist, l.title))
            love[key, default: 0] += 1
            t.likesByArtist[key, default: 0] += 1
        }
        for f in data.followed {
            guard let key = note(f.name, f.id) else { continue }
            love[key, default: 0] += 4
        }
        for a in data.account.artists {
            guard let key = note(a, data.account.artistIds[a.lowercased()]) else { continue }
            love[key, default: 0] += 4
        }
        t.favorites = love.filter { $0.value >= minLove }.sorted { $0.value > $1.value }.prefix(40).map {
            Favorite(name: names[$0.key] ?? $0.key, id: ids[$0.key], score: $0.value)
        }
        return t
    }

    /// Каталожные id для сильнейших любимых, у которых есть только имя.
    static func resolveIds(_ favorites: [Favorite], api: SpotifyAPI) async -> [Favorite] {
        await withTaskGroup(of: (Int, Favorite).self) { group in
            for (i, f) in favorites.enumerated() {
                group.addTask {
                    if f.id != nil || i >= 20 { return (i, f) }
                    var g = f
                    g.id = await ForYouRecommender.exactArtist(f.name, api: api)
                    return (i, g)
                }
            }
            var out = favorites
            for await (i, f) in group { out[i] = f }
            return out
        }
    }

    /// `count` любимых случайно (чем любимее, тем вероятнее) из сильнейших `pool`.
    static func pick(_ favorites: [Favorite], _ count: Int, pool: Int, _ rng: inout SeededRandom) -> [Favorite] {
        var left = Array(favorites.filter { $0.id != nil }.prefix(pool))
        var out: [Favorite] = []
        while out.count < count && !left.isEmpty {
            let total = left.reduce(0.0) { $0 + $1.score }
            var r = rng.nextDouble() * total
            var index = left.count - 1
            for (i, f) in left.enumerated() {
                r -= f.score
                if r <= 0 { index = i; break }
            }
            out.append(left.remove(at: index))
        }
        return out
    }

    // MARK: - Ряды

    /// «Рядом с»: два любимых, новые каждый день, и треки близких к ним артистов.
    static func similar(_ favorites: [Favorite], _ taste: Taste, _ hideExplicit: Bool, _ rotation: UInt64, _ api: SpotifyAPI) async -> [SimilarRow] {
        var rng = SeededRandom(rotation)
        let seeds = pick(favorites, 2, pool: 12, &rng)
        let rows: [SimilarRow?] = await withTaskGroup(of: (Int, SimilarRow?).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    guard let seedId = seed.id else { return (index, nil) }
                    var rowRng = SeededRandom(rotation &* 31 &+ UInt64(index))
                    async let image = artistImage(seedId, api)
                    let spotifyRelated = ((try? await api.artistRelatedArtists(seedId)) ?? [])
                        .filter { !$0.id.isEmpty && $0.name.lowercased() != seed.name.lowercased() }
                    let alsoOnLastFm = await lastFmSimilar(seed.name)
                    // Сначала те, на ком сходятся оба сервиса.
                    let agreed = spotifyRelated.filter { alsoOnLastFm.contains(RadioKeys.norm($0.name)) }
                    let base = agreed.count >= 5 ? agreed : Array(spotifyRelated.prefix(10))
                    let related = Array(rowRng.shuffle(Array(base.prefix(15))).prefix(7))
                    let tracks = await tracksOf(related.map { $0.id }, taste, hideExplicit, &rowRng, api)
                    return (index, SimilarRow(artist: seed.name, artistId: seedId, image: await image, tracks: tracks))
                }
            }
            var out = [SimilarRow?](repeating: nil, count: seeds.count)
            for await (i, r) in group { out[i] = r }
            return out
        }
        return rows.compactMap { $0 }.filter { $0.tracks.count >= 4 }
    }

    struct GenreStats { var top: [String]; var rows: [String]; var artistsOf: [String: [String]] }

    /// Жанры слишком широкие, чтобы что-то говорить о вкусе.
    static let umbrella: Set<String> = [
        "metal", "rock", "pop", "hip-hop", "electronic", "alternative rock", "alternative", "indie",
        "punk", "dance", "experimental", "electronic dance", "hard rock", "heavy metal", "soundtrack",
        "classical", "jazz", "folk", "r&b", "soul", "rap",
    ]

    /// Жанры слушателя: жанры каждого артиста, взвешенные любовью и прослушиваниями. Ряды — двум сильнейшим
    /// и тому, где лайков много для того, как мало он слушается.
    static func genreStats(_ taste: Taste) async -> GenreStats {
        var artists: [String] = []
        var seen = Set<String>()
        for name in taste.favorites.prefix(40).map({ $0.name }) + taste.playsByArtist.sorted(by: { $0.value > $1.value }).prefix(30).map({ $0.key }) {
            if seen.insert(name.lowercased()).inserted { artists.append(name) }
        }
        for name in artists { _ = await Genres.shared.of(name) }
        var loveScore: [String: Double] = [:]
        var likeScore: [String: Double] = [:]
        var playScore: [String: Double] = [:]
        var artistsOf: [String: [String]] = [:]
        var favoriteScore: [String: Double] = [:]
        for f in taste.favorites { favoriteScore[f.name.lowercased()] = f.score }
        for name in artists {
            let key = name.lowercased()
            var genres: [String] = []
            for g in Genres.shared.cached(name) where !umbrella.contains(g.lowercased()) && !genres.contains(g) { genres.append(g) }
            for (i, g) in genres.prefix(2).enumerated() {
                let part = i == 0 ? 1.0 : 0.5
                loveScore[g, default: 0] += (favoriteScore[key] ?? 0) * part
                likeScore[g, default: 0] += Double(taste.likesByArtist[key] ?? 0) * part
                playScore[g, default: 0] += (taste.playsByArtist[key] ?? 0) * part
                artistsOf[g, default: []].append(name)
            }
        }
        let totalLove = max(1.0, loveScore.values.reduce(0, +))
        let totalPlays = max(1.0, playScore.values.reduce(0, +))
        let totalLikes = max(1.0, likeScore.values.reduce(0, +))
        var combined: [String: Double] = [:]
        for (g, l) in loveScore { combined[g] = l / totalLove + (playScore[g] ?? 0) / totalPlays }
        let top = combined.sorted { $0.value > $1.value }.map { $0.key }
        let rowWorthy = top.filter { g in (artistsOf[g] ?? []).filter { favoriteScore[$0.lowercased()] != nil }.count >= 2 }
        let main = Array(rowWorthy.prefix(2))
        func lovedRatio(_ g: String, _ likes: Double) -> Double {
            let liked: Double = likes / totalLikes
            let played: Double = (playScore[g] ?? 0) / totalPlays + 0.02
            return liked / played
        }
        let lovedMore = likeScore.filter { !main.contains($0.key) && rowWorthy.contains($0.key) && $0.value >= 3 }
            .max { lovedRatio($0.key, $0.value) < lovedRatio($1.key, $1.value) }?.key
        return GenreStats(top: Array(top.prefix(10)), rows: main + (lovedMore.map { [$0] } ?? []), artistsOf: artistsOf)
    }

    /// «Похожее в <жанре>»: артисты, близкие к любимым в этом жанре, внутри жанра и новые слушателю.
    static func genreRows(_ stats: GenreStats, _ favorites: [Favorite], _ taste: Taste, _ hideExplicit: Bool,
                                      _ rotation: UInt64, _ api: SpotifyAPI) async -> [SimilarRow] {
        var byName: [String: Favorite] = [:]
        for f in favorites { byName[f.name.lowercased()] = f }
        let rows: [SimilarRow?] = await withTaskGroup(of: (Int, SimilarRow?).self) { group in
            for (index, genre) in stats.rows.enumerated() {
                group.addTask {
                    var rng = SeededRandom(rotation &* 17 &+ UInt64(index))
                    let ofGenre = await GenrePlaylists.shared.topArtistsOf(genre)
                    func inGenre(_ name: String) -> Bool {
                        ofGenre.contains(RadioKeys.norm(name)) || Genres.shared.cached(name).contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
                    }
                    let mine = (stats.artistsOf[genre] ?? []).compactMap { byName[$0.lowercased()] }.filter { $0.id != nil }
                    let seeds = pick(mine, 4, pool: 8, &rng)
                    var related: [SpotifyArtist] = []
                    for seed in seeds {
                        related += ((try? await api.artistRelatedArtists(seed.id ?? "")) ?? [])
                    }
                    related = related.filter { !$0.id.isEmpty && !taste.knownArtists.contains($0.name.lowercased()) }
                    var counted: [String: Int] = [:]
                    for a in related { counted[a.id, default: 0] += 1 }
                    var seenIds = Set<String>()
                    let distinct = related.filter { seenIds.insert($0.id).inserted }
                        .sorted { (counted[$0.id] ?? 0) + (inGenre($0.name) ? 2 : 0) > (counted[$1.id] ?? 0) + (inGenre($1.name) ? 2 : 0) }
                    let candidates = Array(rng.shuffle(Array((distinct.filter { inGenre($0.name) } + distinct.filter { !inGenre($0.name) }).prefix(12))).prefix(7))
                    let tracks = await tracksOf(candidates.map { $0.id }, taste, hideExplicit, &rng, api)
                    return (index, SimilarRow(artist: seeds.first?.name ?? "", artistId: nil, image: nil, tracks: tracks, genre: genre))
                }
            }
            var out = [SimilarRow?](repeating: nil, count: stats.rows.count)
            for await (i, r) in group { out[i] = r }
            return out
        }
        return rows.compactMap { $0 }.filter { $0.tracks.count >= 4 }
    }

    /// «Глубже в каталог»: треки альбомов любимых артистов — не хиты и ещё не слышанные.
    static func deepCuts(_ favorites: [Favorite], _ taste: Taste, _ hideExplicit: Bool, _ rotation: UInt64, _ api: SpotifyAPI) async -> [SpotifyTrack] {
        var rng = SeededRandom(rotation &* 7 &+ 3)
        let seeds = pick(favorites, 5, pool: 15, &rng)
        let lists: [[SpotifyTrack]] = await withTaskGroup(of: (Int, [SpotifyTrack]).self) { group in
            for (i, seed) in seeds.enumerated() {
                group.addTask {
                    guard let id = seed.id else { return (i, []) }
                    var r = SeededRandom(rotation &+ UInt64(i) &* 101)
                    let hits = Set(((try? await api.artistTopTracks(id)) ?? []).map { $0.id })
                    let disco = try? await api.artistDiscography(id)
                    let albums = Array(r.shuffle((disco?.albums ?? []) + (disco?.singles ?? []).filter { $0.totalTracks >= 4 }).prefix(2))
                    var out: [SpotifyTrack] = []
                    for release in albums {
                        guard let album = try? await api.album(release.id) else { continue }
                        let cover = SpotifySimpleAlbum(id: album.id, name: album.name, images: album.images.isEmpty ? release.images : album.images,
                                                       releaseDate: album.releaseDate, albumType: album.albumType, artists: album.artists)
                        let picks = album.tracks.filter { t in
                            !t.id.isEmpty && !hits.contains(t.id) && !t.isLocal && !(hideExplicit && t.explicit) &&
                                !taste.known.contains(RadioKeys.trackKey(t.artists.first?.name ?? seed.name, t.name))
                        }
                        for var t in r.shuffle(picks).prefix(2) {
                            if t.album?.images.isEmpty ?? true { t.album = cover }
                            out.append(t)
                        }
                    }
                    return (i, out)
                }
            }
            var out = [[SpotifyTrack]](repeating: [], count: seeds.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        return Array(RadioKeys.interleave(lists).prefix(14))
    }

    /// Альбомы и EP любимых артистов, что не слушались или брошены после пары треков; не больше двух у артиста.
    static func unheardAlbums(_ favorites: [Favorite], _ taste: Taste, _ rotation: UInt64, _ api: SpotifyAPI) async -> [SpotifyAlbum] {
        var rng = SeededRandom(rotation &* 11 &+ 5)
        let seeds = pick(favorites, 10, pool: 20, &rng)
        let lists: [[SpotifyAlbum]] = await withTaskGroup(of: (Int, [SpotifyAlbum]).self) { group in
            for (i, f) in seeds.enumerated() {
                group.addTask {
                    guard let id = f.id, let disco = try? await api.artistDiscography(id) else { return (i, []) }
                    var r = SeededRandom(rotation &+ UInt64(i) &* 977)
                    let candidates = (disco.albums + disco.singles).filter { album in
                        let type = (album.albumType ?? "").lowercased()
                        let full = type == "album" || type == "ep" || album.totalTracks >= 4
                        return full && (taste.albumTracks[RadioKeys.albumKey(f.name, album.name)]?.count ?? 0) < 3
                    }
                    let picked = r.shuffle(candidates).prefix(2).map { a -> SpotifyAlbum in
                        var a = a
                        if a.artists.isEmpty { a.artists = [SpotifySimpleArtist(id: id, name: f.name)] }
                        a.tracks = []
                        return a
                    }
                    return (i, Array(picked))
                }
            }
            var out = [[SpotifyAlbum]](repeating: [], count: seeds.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        var seen = Set<String>()
        return Array(RadioKeys.interleave(lists).filter { seen.insert($0.id).inserted }.prefix(16))
    }

    private static var similarMemory: [String: Set<String>] = [:]
    private static let memoryLock = NSLock()

    /// Похожие артисты Last.fm, нормализованные; пусто, если Last.fm их не знает.
    static func lastFmSimilar(_ artist: String) async -> Set<String> {
        memoryLock.lock(); let kept = similarMemory[artist.lowercased()]; memoryLock.unlock()
        if let kept = kept { return kept }
        var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        c.queryItems = [
            URLQueryItem(name: "method", value: "artist.getsimilar"), URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"), URLQueryItem(name: "limit", value: "150"),
            URLQueryItem(name: "api_key", value: Genres.apiKey), URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = c.url, let r = try? await HTTP.get(url, timeout: 12), r.isSuccess, let o = JSON.object(r.data) else { return [] }
        let names = Set((o.obj("similarartists")?.objects("artist") ?? []).compactMap { $0.str("name") }.filter { !$0.isEmpty }.map(RadioKeys.norm))
        if !names.isEmpty { memoryLock.lock(); similarMemory[artist.lowercased()] = names; memoryLock.unlock() }
        return names
    }

    /// По два новых слушателю хита каждого артиста, вперемешку.
    static func tracksOf(_ ids: [String], _ taste: Taste, _ hideExplicit: Bool, _ rng: inout SeededRandom, _ api: SpotifyAPI) async -> [SpotifyTrack] {
        let seeds = ids.map { _ in rng.next() }
        let lists: [[SpotifyTrack]] = await withTaskGroup(of: (Int, [SpotifyTrack]).self) { group in
            for (i, id) in ids.enumerated() {
                let seed = seeds[i]
                group.addTask {
                    var r = SeededRandom(seed)
                    let top = ((try? await api.artistTopTracks(id)) ?? []).filter { t in
                        !t.id.isEmpty && !t.isLocal && !(hideExplicit && t.explicit) &&
                            !taste.known.contains(RadioKeys.trackKey(t.artists.first?.name ?? "", t.name))
                    }
                    return (i, Array(r.shuffle(Array(top.prefix(5))).prefix(2)))
                }
            }
            var out = [[SpotifyTrack]](repeating: [], count: ids.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        return Array(RadioKeys.interleave(lists).prefix(14))
    }

    static func artistImage(_ id: String, _ api: SpotifyAPI) async -> String? {
        guard let a = try? await api.artist(id) else { return nil }
        return (a.images.first { (200...400).contains($0.width ?? 0) } ?? a.images.first)?.url
    }

    /// Лайки, которые давно не звучали.
    static func forgotten(_ taste: Taste, _ hideExplicit: Bool, _ rotation: UInt64) -> [SpotifyTrack] {
        let longAgo = Int64((Date().timeIntervalSince1970 - forgottenAfterDays * 86400) * 1000)
        var rng = SeededRandom(rotation)
        let candidates = taste.likedTracks.filter { t in
            let at = taste.likedAt[t.id] ?? 0
            return !t.id.isEmpty && !(hideExplicit && t.explicit) && at > 0 && at < longAgo &&
                !taste.recentlyHeard.contains(RadioKeys.trackKey(t.artists.first?.name ?? "", t.name))
        }
        var seen = Set<String>()
        return Array(rng.shuffle(candidates).filter { seen.insert($0.artists.first?.name.lowercased() ?? "").inserted }.prefix(16))
    }
}

/// Повторяемый генератор случайных чисел (SplitMix64): «день выбирает ряды», как `Random(rotation)` на Android.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func shuffle<T>(_ items: [T]) -> [T] {
        var a = items
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
        return a
    }
}
