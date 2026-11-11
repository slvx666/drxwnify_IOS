import Foundation

/// Продолжение очереди (PLAY-007): что играет само, когда треки кончаются. Как `continueWith` у очередей Android.
protocol RadioSource: AnyObject {
    /// Следующая порция; `queued` — всё, что уже стоит в очереди (повторы отсеивает плеер).
    func more(after queued: [Track]) async -> [Track]
}

/// Общие мелочи рекомендаций.
enum RadioKeys {
    /// «артист|название» без скобок и « - …», только буквы и цифры (как `trackKey` на Android).
    static func trackKey(_ artist: String, _ title: String) -> String {
        var t = title.lowercased()
        if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        return norm(artist) + "|" + norm(t)
    }

    static func albumKey(_ artist: String, _ album: String) -> String {
        var a = album.lowercased()
        if let r = a.range(of: " (") { a = String(a[..<r.lowerBound]) }
        return norm(artist) + "|" + norm(a)
    }

    static func norm(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x400 && $0.value <= 0x4FF }
    }

    /// По очереди из каждого списка — чтобы ни один не шёл подряд.
    static func interleave<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        let longest = lists.map { $0.count }.max() ?? 0
        for i in 0..<longest {
            for l in lists where i < l.count { out.append(l[i]) }
        }
        return out
    }

    /// `count` случайных по весу (чем больше вес, тем вероятнее), без повторов.
    static func weightedSample<T>(_ items: [(T, Double)], _ count: Int) -> [T] {
        var left = items
        var out: [T] = []
        while out.count < count && !left.isEmpty {
            let total = left.reduce(0.0) { $0 + max(0.01, $1.1) }
            var r = Double.random(in: 0..<total)
            var index = left.count - 1
            for (i, item) in left.enumerated() {
                r -= max(0.01, item.1)
                if r <= 0 { index = i; break }
            }
            out.append(left.remove(at: index).0)
        }
        return out
    }

    /// Каталожный id из id артиста в базе (`spotify:…` с Android, `ym_…`, голый id Spotify).
    static func catalogArtistId(_ id: String?) -> String? {
        guard let id = id, !id.isEmpty else { return nil }
        if id.hasPrefix("spotify:") { return String(id.dropFirst("spotify:".count)) }
        if YandexIds.isYandex(id) { return id }
        if id.count == 22 && id.allSatisfy({ $0.isLetter || $0.isNumber }) { return id }
        return nil
    }
}

/// Треки каталога, что реально звучали последние 3 дня (`RecentlyPlayed.kt`): радио не возвращает только что слышанное.
final class RecentlyPlayed {
    static let shared = RecentlyPlayed()
    private static let keepDays: Double = 3
    private static let maxKept = 2000
    private let defaults = UserDefaults(suiteName: "recently_played") ?? .standard
    private let lock = NSLock()

    static func keyOf(artist: String?, title: String) -> String {
        var s = ((artist ?? "") + "|" + title).lowercased()
        if let r = s.range(of: #"\s*[(\[].*"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        return "k:" + s.trimmingCharacters(in: .whitespaces)
    }

    static func keyOf(_ t: Track) -> String { keyOf(artist: t.artists.first?.name, title: t.title) }

    func record(_ t: Track) {
        guard let id = t.catalogId else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var all = (defaults.dictionary(forKey: "all") as? [String: Double]) ?? [:]
        all["id:" + id] = now
        all[Self.keyOf(t)] = now
        let cutoff = now - Self.keepDays * 86400
        all = all.filter { $0.value >= cutoff }
        if all.count > Self.maxKept {
            let drop = all.sorted { $0.value < $1.value }.prefix(all.count - Self.maxKept).map { $0.key }
            drop.forEach { all.removeValue(forKey: $0) }
        }
        defaults.set(all, forKey: "all")
    }

    func snapshot() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().timeIntervalSince1970 - Self.keepDays * 86400
        let all = (defaults.dictionary(forKey: "all") as? [String: Double]) ?? [:]
        return Set(all.filter { $0.value >= cutoff }.keys)
    }

    static func contains(_ t: Track, in recent: Set<String>) -> Bool {
        (t.catalogId.map { recent.contains("id:" + $0) } ?? false) || recent.contains(keyOf(t))
    }
}

/// Треки, что выбрало само приложение (радио, «Для тебя», похожие): им нельзя играть ниже 120 kbps (PLAY-010).
final class RecommendedTracks {
    static let shared = RecommendedTracks()
    static let minKbps = 120
    private var ids = Set<String>()
    private var order: [String] = []
    private let lock = NSLock()

    func mark(_ tracks: [Track]) {
        lock.lock(); defer { lock.unlock() }
        for t in tracks where ids.insert(t.id).inserted { order.append(t.id) }
        if order.count > 4000 {
            let drop = order.prefix(order.count - 4000)
            drop.forEach { ids.remove($0) }
            order.removeFirst(drop.count)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        ids.removeAll(); order.removeAll()
    }

    func isRecommended(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    func tooLow(_ id: String, bitrate: Int) -> Bool {
        bitrate > 0 && bitrate < Self.minKbps * 1000 && isRecommended(id)
    }
}

/// «Что играет дальше» для трека (`SimilarArtistsRadio.kt`): песни похожих артистов каталога и немного — самого артиста.
enum SimilarArtistsRadio {
    private static let relatedArtists = 12
    private static let perRelated = 3
    private static let seedArtistTracks = 6
    private static let seedEvery = 4
    private static let minFresh = 8

    static func build(seed: Track, api: SpotifyAPI, limit: Int = 50) async -> [Track] {
        guard let artistId = seed.artists.compactMap({ RadioKeys.catalogArtistId($0.id) ?? (($0.id ?? "").isEmpty ? nil : $0.id) }).first else { return [] }
        async let seedTopTask: [SpotifyTrack] = (try? await api.artistTopTracks(artistId)) ?? []
        let related = Array(((try? await api.artistRelatedArtists(artistId)) ?? []).filter { !$0.id.isEmpty && $0.id != artistId }.prefix(relatedArtists))
        let relatedTops: [[SpotifyTrack]] = await withTaskGroup(of: (Int, [SpotifyTrack]).self) { group in
            for (i, a) in related.enumerated() {
                group.addTask { (i, (try? await api.artistTopTracks(a.id)) ?? []) }
            }
            var out = [[SpotifyTrack]](repeating: [], count: related.count)
            for await (i, list) in group { out[i] = list }
            return out
        }
        let seedTop = await seedTopTask

        var seen = Set<String>()
        let recent = RecentlyPlayed.shared.snapshot()
        var heardRecently: [Track] = []
        let seedKey = RecentlyPlayed.keyOf(seed)
        func accept(_ s: SpotifyTrack) -> Track? {
            if s.id.isEmpty || s.isLocal { return nil }
            let t = Track(s)
            let key = RecentlyPlayed.keyOf(t)
            if t.id == seed.id || key == seedKey || seen.contains(s.id) || seen.contains(key) { return nil }
            seen.insert(s.id); seen.insert(key)
            if RecentlyPlayed.contains(t, in: recent) { heardRecently.append(t); return nil }
            return t
        }

        let perArtist: [[SpotifyTrack]] = relatedTops.map { Array(Array($0.prefix(8)).shuffled().prefix(perRelated)) }
        var relatedOrder: [SpotifyTrack] = []
        for round in 0..<perRelated {
            for picks in perArtist where round < picks.count { relatedOrder.append(picks[round]) }
        }
        var seedPicks = Array(seedTop.shuffled().prefix(seedArtistTracks))
        var result: [Track] = []
        var sinceSeed = 0
        for s in relatedOrder {
            if result.count >= limit { break }
            if sinceSeed >= seedEvery, !seedPicks.isEmpty {
                if let t = accept(seedPicks.removeFirst()) { result.append(t) }
                sinceSeed = 0
            }
            if let t = accept(s) { result.append(t); sinceSeed += 1 }
        }
        for s in seedPicks where result.count < limit {
            if let t = accept(s) { result.append(t) }
        }
        if result.count < minFresh {
            for t in heardRecently where result.count < minFresh { result.append(t) }
        }
        return result
    }
}

/// После альбома или плейлиста — радио похожих артистов без конца (`SpotifyPlaylistQueue.continueWith`):
/// зерно попеременно из исходного списка и из того, докуда дошло радио.
final class ListRadio: RadioSource {
    private let original: [Track]
    private let api: SpotifyAPI
    private var round = 0

    init(original: [Track], api: SpotifyAPI) {
        self.original = original.filter { $0.catalogId != nil }
        self.api = api
    }

    func more(after queued: [Track]) async -> [Track] {
        let pool: [Track] = round % 2 == 0 ? (original.isEmpty ? queued : original) : Array(queued.suffix(10))
        round += 1
        guard let seed = pool.filter({ $0.catalogId != nil }).randomElement() else { return [] }
        return await SimilarArtistsRadio.build(seed: seed, api: api)
    }
}

/// Топ артиста → его другие песни → похожие (`ArtistTopTracksQueue.kt`); `shuffleAll` — «Перемешать» у артиста:
/// все песни артиста без повторов, потом похожие.
final class ArtistRadio: RadioSource {
    private let artistId: String
    private let shuffleAll: Bool
    private let api: SpotifyAPI
    private var round = 0
    private static let releasesToScan = 6
    private static let allReleasesToScan = 40

    /// `discographyQueued` — вся дискография уже в очереди («Перемешать»): дальше сразу похожие.
    init(artistId: String, shuffleAll: Bool, api: SpotifyAPI, discographyQueued: Bool = false) {
        self.artistId = artistId
        self.shuffleAll = shuffleAll
        self.api = api
        self.round = discographyQueued ? 1 : 0
    }

    /// Вся дискография артиста (альбомы и синглы, до 40 релизов) без повторов по названию, вместе с популярными.
    static func discography(artistId: String, top: [Track], api: SpotifyAPI) async -> [Track] {
        let more = await ArtistRadio(artistId: artistId, shuffleAll: true, api: api).moreFromArtist(allReleasesToScan)
        var seen = Set<String>()
        return (top + more).filter { seen.insert(titleKey($0)).inserted }
    }

    private static func titleKey(_ t: Track) -> String {
        var s = t.title.lowercased()
        if let r = s.range(of: #"\s*[(\[].*"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    func more(after queued: [Track]) async -> [Track] {
        let current = round
        round += 1
        let seenIds = Set(queued.map { $0.id })
        var seenTitles = Set(queued.map { Self.titleKey($0) })
        func fresh(_ list: [Track]) -> [Track] {
            list.filter { t in
                guard !seenIds.contains(t.id) else { return false }
                return seenTitles.insert(Self.titleKey(t)).inserted
            }
        }
        if current == 0 {
            let more = await moreFromArtist(shuffleAll ? Self.allReleasesToScan : Self.releasesToScan)
            let list = fresh(more).shuffled()
            return shuffleAll ? list : Array(list.prefix(Int.random(in: 8...15)))
        }
        guard let seed = queued.last(where: { t in t.artists.contains { $0.id == artistId } }) ?? queued.first else { return [] }
        return fresh(await SimilarArtistsRadio.build(seed: seed, api: api))
    }

    /// Песни из релизов артиста, новые первыми, сверх популярных.
    private func moreFromArtist(_ scan: Int) async -> [Track] {
        guard let disco = try? await api.artistDiscography(artistId) else { return [] }
        let releases = Array((disco.albums + disco.singles).sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }.prefix(scan))
        let api = self.api
        let artistId = self.artistId
        let lists: [[Track]] = await withTaskGroup(of: (Int, [Track]).self) { group in
            for (i, r) in releases.enumerated() {
                group.addTask {
                    guard let album = try? await api.album(r.id) else { return (i, []) }
                    let tracks = album.tracks.filter { t in t.artists.isEmpty || t.artists.contains { $0.id == artistId } }
                    return (i, tracks.map { Track($0, album: album.simple) })
                }
            }
            var out = [[Track]](repeating: [], count: releases.count)
            for await (i, l) in group { out[i] = l }
            return out
        }
        return lists.flatMap { $0 }
    }
}
