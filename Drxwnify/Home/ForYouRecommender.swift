import Foundation

/// Что «Для тебя» уже выдавало за 10 дней (`ForYouSeen.kt`): миксы Spotify меняются медленно, без памяти
/// одни и те же треки возвращались каждый день.
final class ForYouSeen {
    static let shared = ForYouSeen()
    private static let keepDays: Double = 10
    private static let maxKept = 3000
    private let defaults = UserDefaults(suiteName: "for_you_seen") ?? .standard
    private let lock = NSLock()

    private func all() -> [String: Double] { (defaults.dictionary(forKey: "all") as? [String: Double]) ?? [:] }

    func recent() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().timeIntervalSince1970 - Self.keepDays * 86400
        return Set(all().filter { $0.value >= cutoff }.keys)
    }

    func seenAt(_ id: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        return all()[id] ?? 0
    }

    func record(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var map = all().filter { $0.value >= now - Self.keepDays * 86400 }
        ids.forEach { map[$0] = now }
        if map.count > Self.maxKept {
            map.sorted { $0.value < $1.value }.prefix(map.count - Self.maxKept).forEach { map.removeValue(forKey: $0.key) }
        }
        defaults.set(map, forKey: "all")
    }
}

/// Ряд «Для тебя» и его бесконечное радио (`playback/ForYouRecommender.kt`, HOME-002, HOME-011).
///
/// 1. Со Spotify сначала его личные миксы (Discover Weekly, Daily Mix, Release Radar).
/// 2. Потом — из вкуса, как его видит приложение: недавние прослушивания (сильнее всего), лайки, подписки;
///    каждый сильный артист приносит треки близких к нему.
/// Всё фильтруется: без уже лайкнутого и недавно слышанного, не больше двух треков артиста,
/// и без кириллицы тому, кто её почти не слушает.
enum ForYouRecommender {
    /// 35 обложек + кубик = 36 клеток: четыре страницы 3×3.
    static let target = 35
    private static let maxPerArtist = 2
    private static let cyrillicMinShare = 0.15
    private static let maxEmptyRounds = 6

    struct Taste {
        /// Ключ артиста (`id:` каталожный или `name:` имя) → вес.
        var artists: [String: Double]
        var names: [String: String]
        var knownTracks: Set<String>
        var cyrillicShare: Double
    }

    static func taste(_ data: TasteData) -> Taste {
        var weights: [String: Double] = [:]
        var names: [String: String] = [:]
        var known = Set<String>()
        var cyrillic = 0
        var total = 0

        func add(_ id: String?, _ name: String, _ weight: Double) {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            let key = id.map { "id:" + $0 } ?? ("name:" + n.lowercased())
            weights[key, default: 0] += weight
            if names[key] == nil { names[key] = n }
        }
        func sample(_ artist: String, _ title: String) {
            total += 1
            if RadioKeys.hasCyrillic(artist) || RadioKeys.hasCyrillic(title) { cyrillic += 1 }
            known.insert(RadioKeys.trackKey(artist, title))
        }

        // Недавние прослушивания — главный сигнал; две недели назад весят примерно вдвое меньше.
        for p in data.plays.prefix(600) {
            sample(p.artist, p.title)
            add(p.artistId, p.artist, 3.0 * exp(-p.ageDays / 20.0))
        }
        for l in data.liked.prefix(300) {
            sample(l.artist, l.title)
            add(l.artistId, l.artist, 2.0)
        }
        for f in data.followed { add(f.id, f.name, 3.0) }
        for t in data.account.tracks {
            sample(t.artists.first?.name ?? "", t.name)
            for a in t.artists.prefix(2) { add(RadioKeys.catalogArtistId(a.id) ?? a.id, a.name, 2.0) }
        }
        for a in data.account.artists { add(data.account.artistIds[a.lowercased()], a, 3.0) }
        return Taste(artists: weights, names: names, knownTracks: known,
                     cyrillicShare: total == 0 ? 1.0 : Double(cyrillic) / Double(total))
    }

    /// Ряд на главной.
    static func build(_ data: TasteData, api: SpotifyAPI, hideExplicit: Bool) async -> [SpotifyTrack] {
        await Session(data: data, api: api, hideExplicit: hideExplicit).next(target)
    }

    /// Бесконечный поток рекомендаций порциями: внутри сессии ничего не повторяется, сначала миксы Spotify,
    /// потом каждая порция — из другого случайного (по весу) набора артистов слушателя.
    actor Session {
        private let api: SpotifyAPI
        private let hideExplicit: Bool
        private let data: TasteData
        private var used: Set<String>
        private let seenBefore: Set<String>
        private var pool: [SpotifyTrack] = []
        private var taste: Taste?
        private var seeds: [(String, Double)]?
        private var mixesTried = false
        private var emptyRounds = 0

        init(data: TasteData, api: SpotifyAPI, hideExplicit: Bool, exclude: [String] = []) {
            self.data = data
            self.api = api
            self.hideExplicit = hideExplicit
            used = Set(exclude)
            seenBefore = ForYouSeen.shared.recent()
        }

        func next(_ count: Int) async -> [SpotifyTrack] {
            let t = taste ?? ForYouRecommender.taste(data)
            taste = t
            while pool.filter({ !used.contains($0.id) && !seenBefore.contains($0.id) }).count < count && emptyRounds < ForYouRecommender.maxEmptyRounds {
                let more: [SpotifyTrack]
                if !mixesTried {
                    mixesTried = true
                    more = api.yandexIsSource ? [] : await ForYouRecommender.madeForYou(api)
                } else {
                    if seeds == nil { seeds = await ForYouRecommender.resolveSeeds(t, api: api) }
                    more = await ForYouRecommender.fromTaste(seeds ?? [], api: api)
                }
                let poolIds = Set(pool.map { $0.id })
                let fresh = ForYouRecommender.diversify(ForYouRecommender.filter(more, t, hideExplicit: hideExplicit)
                    .filter { !used.contains($0.id) && !poolIds.contains($0.id) })
                if fresh.allSatisfy({ seenBefore.contains($0.id) }) { emptyRounds += 1 } else { emptyRounds = 0 }
                pool.append(contentsOf: fresh)
            }
            var out: [SpotifyTrack] = []
            var skipped: [SpotifyTrack] = []
            while out.count < count, !pool.isEmpty {
                let track = pool.removeFirst()
                if used.contains(track.id) { continue }
                if seenBefore.contains(track.id) { skipped.append(track); continue }
                used.insert(track.id)
                out.append(track)
            }
            // Нового нет: лучше старая рекомендация, чем пустое радио — давние первыми.
            for track in skipped.sorted(by: { ForYouSeen.shared.seenAt($0.id) < ForYouSeen.shared.seenAt($1.id) }) where out.count < count {
                if used.insert(track.id).inserted { out.append(track) }
            }
            ForYouSeen.shared.record(out.map { $0.id })
            return out
        }
    }

    private static let mixName = try! NSRegularExpression(pattern: "Discover Weekly|Daily Mix|Release Radar|Mix|daylist|Открытия недели|Микс|Радар новинок", options: .caseInsensitive)
    private static let mixPriority: [NSRegularExpression] = [
        "Discover Weekly|Открытия недели", "Daily Mix|Микс дня", "Release Radar|Радар новинок", "Mix|Микс",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Треки личных миксов Spotify вперемешку, чтобы ни один не главенствовал.
    static func madeForYou(_ api: SpotifyAPI) async -> [SpotifyTrack] {
        guard let home = try? await api.home(sectionItemsLimit: 20) else { return [] }
        var seen = Set<String>()
        let playlists = home.sections.flatMap { $0.items }
            .filter { $0.kind == .playlist && ($0.madeFor != nil || matches(mixName, $0.name)) }
            .filter { seen.insert($0.id).inserted }
            .sorted { a, b in
                func rank(_ p: SpotifyHomeItem) -> Int { mixPriority.firstIndex { matches($0, p.name) } ?? 99 }
                return rank(a) < rank(b)
            }
            .prefix(6)
        let lists: [[SpotifyTrack]] = await withTaskGroup(of: (Int, [SpotifyTrack]).self) { group in
            for (i, p) in playlists.enumerated() {
                group.addTask {
                    let page = try? await api.playlistTracks(p.id, limit: 50, offset: 0)
                    return (i, (page?.items.map { $0.track } ?? []).filter { !$0.id.isEmpty && !$0.isLocal }.shuffled())
                }
            }
            var out = [[SpotifyTrack]](repeating: [], count: playlists.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        return RadioKeys.interleave(lists)
    }

    /// Каталожные id 20 самых сильных артистов с весами. Имя засчитывается, только если в каталоге есть артист
    /// ровно с таким именем (загрузчик SoundCloud приводил незнакомца с его «похожими»).
    static func resolveSeeds(_ taste: Taste, api: SpotifyAPI) async -> [(String, Double)] {
        let top = taste.artists.sorted { $0.value > $1.value }.prefix(20)
        var out: [(String, Double)] = []
        var seen = Set<String>()
        for (key, weight) in top {
            let id: String?
            if key.hasPrefix("id:") {
                id = String(key.dropFirst(3))
            } else {
                id = await exactArtist(taste.names[key] ?? String(key.dropFirst(5)), api: api)
            }
            if let id = id, seen.insert(id).inserted { out.append((id, weight)) }
        }
        return out
    }

    static func exactArtist(_ name: String, api: SpotifyAPI) async -> String? {
        let wanted = RadioKeys.norm(name)
        guard !wanted.isEmpty, let r = try? await api.search(name, limit: 5) else { return nil }
        return r.artists.first { !$0.id.isEmpty && RadioKeys.norm($0.name) == wanted }?.id
    }

    /// Один круг: восемь зёрен случайно по весу, у каждого — 4 близких артиста по 3 трека.
    static func fromTaste(_ seeds: [(String, Double)], api: SpotifyAPI) async -> [SpotifyTrack] {
        guard !seeds.isEmpty else { return [] }
        let seedSet = Set(seeds.map { $0.0 })
        let picked = RadioKeys.weightedSample(seeds, 8)
        let lists: [[SpotifyTrack]] = await withTaskGroup(of: (Int, [SpotifyTrack]).self) { group in
            for (i, seed) in picked.enumerated() {
                group.addTask {
                    let related = ((try? await api.artistRelatedArtists(seed)) ?? [])
                        .filter { !$0.id.isEmpty && !seedSet.contains($0.id) }
                    var out: [SpotifyTrack] = []
                    for a in Array(Array(related.prefix(20)).shuffled().prefix(4)) {
                        let top = (try? await api.artistTopTracks(a.id)) ?? []
                        out.append(contentsOf: top.shuffled().prefix(3))
                    }
                    return (i, out)
                }
            }
            var out = [[SpotifyTrack]](repeating: [], count: picked.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        return RadioKeys.interleave(lists)
    }

    static func filter(_ tracks: [SpotifyTrack], _ taste: Taste, hideExplicit: Bool) -> [SpotifyTrack] {
        tracks.filter { t in
            let artist = t.artists.first?.name ?? ""
            guard !t.id.isEmpty, !t.isLocal, !(hideExplicit && t.explicit) else { return false }
            guard !taste.knownTracks.contains(RadioKeys.trackKey(artist, t.name)) else { return false }
            if taste.cyrillicShare < cyrillicMinShare && (RadioKeys.hasCyrillic(t.name) || t.artists.contains { RadioKeys.hasCyrillic($0.name) }) { return false }
            return !BlockedTracks.shared.isBlocked(Track(t))
        }
    }

    /// Не больше двух треков артиста, вразброс.
    static func diversify(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var perArtist: [String: Int] = [:]
        var order: [String] = []
        var groups: [String: [SpotifyTrack]] = [:]
        for t in tracks {
            let key = t.artists.first?.name.lowercased() ?? ""
            let n = perArtist[key] ?? 0
            if n >= maxPerArtist { continue }
            perArtist[key] = n + 1
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        return RadioKeys.interleave(order.map { groups[$0] ?? [] })
    }
}

/// Радио «Для тебя» (`ForYouQueue.kt`): начинается с выбранных треков и не кончается — каждая порция из сессии,
/// которая не повторяет выданное.
final class ForYouRadio: RadioSource {
    private let session: ForYouRecommender.Session

    init(session: ForYouRecommender.Session) { self.session = session }

    func more(after queued: [Track]) async -> [Track] {
        let have = Set(queued.map { $0.id })
        return await session.next(20).map { Track($0) }.filter { !have.contains($0.id) }
    }
}

