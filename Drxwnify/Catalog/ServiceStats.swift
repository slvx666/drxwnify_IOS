import Foundation

/// Статистика сервисов — только то, что отдаёт сам сервис (Android 2.3.0 `ServiceStats`, раздел 8):
/// Spotify — топы за 4 недели / полгода / всё время (GraphQL `userTopContent`), Яндекс — лайки по месяцам и исполнители
/// с наибольшим числом лайков. Кэш на диске — сутки.
enum ServiceStats {
    struct Artist: Codable, Hashable {
        var id: String
        var name: String
        var image: String?
        /// Яндекс: лайков у исполнителя; Spotify: нет личного числа (0).
        var count: Int = 0
    }

    struct SpotifyTops: Codable {
        var at: Date
        var tracks: [SpotifyTrack]
        var artists: [Artist]
    }

    struct YandexStats: Codable {
        var at: Date
        var total: Int
        /// 12 месяцев, старые слева: («yyyy-MM», лайков).
        var months: [Month]
        var artists: [Artist]
        /// Лайкнутые треки с самым «популярным» исполнителем первыми — для страниц треков в итогах.
        var tracks: [SpotifyTrack]

        struct Month: Codable, Hashable {
            var key: String
            var count: Int
        }
    }

    private static let day: TimeInterval = 24 * 3600

    private static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stats_" + name + ".json")
    }

    private static func read<T: Decodable>(_ name: String) -> T? {
        (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func write<T: Encodable>(_ name: String, _ v: T) {
        try? JSONEncoder().encode(v).write(to: file(name), options: .atomic)
    }

    static func cachedSpotify(_ range: SpotifyAPI.TopRange) -> SpotifyTops? { read("spotify_" + range.rawValue) }

    static func spotify(_ range: SpotifyAPI.TopRange, api: SpotifyAPI, force: Bool = false) async throws -> SpotifyTops {
        if !force, let c = cachedSpotify(range), Date().timeIntervalSince(c.at) < day { return c }
        async let t = api.topTracks(range, limit: 50)
        async let a = api.topArtists(range, limit: 50)
        let tops = SpotifyTops(at: Date(), tracks: try await t,
                               artists: try await a.map { Artist(id: $0.id, name: $0.name, image: $0.images.best(minWidth: 300)) })
        write("spotify_" + range.rawValue, tops)
        return tops
    }

    static func cachedYandex() -> YandexStats? { read("yandex2") }

    static func yandex(api: SpotifyAPI, force: Bool = false) async throws -> YandexStats {
        if !force, let c = cachedYandex(), Date().timeIntervalSince(c.at) < day { return c }
        guard let y = api.yandex else { throw YandexError(status: 401, message: "Yandex") }
        let refs = try await y.likedTrackRefs()
        // Лайки по месяцам: последние 12.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        let cal = Calendar.current
        var byMonth: [String: Int] = [:]
        for r in refs {
            guard let ts = r.timestamp, let d = iso.date(from: ts) ?? iso2.date(from: ts) else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            byMonth[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)] = (byMonth[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)] ?? 0) + 1
        }
        var months: [YandexStats.Month] = []
        for back in (0..<12).reversed() {
            guard let d = cal.date(byAdding: .month, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            months.append(.init(key: key, count: byMonth[key] ?? 0))
        }
        // Исполнители по числу лайков: треки читаются пачками (до 3000 самых свежих лайков).
        var tracks: [SpotifyTrack] = []
        let ids = refs.prefix(3000).map { $0.requestId }
        var i = 0
        while i < ids.count {
            tracks += (try? await y.tracks(Array(ids[i..<min(i + 200, ids.count)]))) ?? []
            i += 200
        }
        var counts: [String: (String, Int, String?)] = [:]
        for t in tracks {
            for a in t.artists {
                guard let id = a.id, !id.isEmpty else { continue }
                let prev = counts[id]
                counts[id] = (a.name, (prev?.1 ?? 0) + 1, prev?.2 ?? t.album?.images.best(minWidth: 300))
            }
        }
        var artists = counts.map { Artist(id: $0.key, name: $0.value.0, image: $0.value.2, count: $0.value.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        artists = Array(artists.prefix(30))
        // Свои фото исполнителей (`artists/<id>/brief-info`); обложка трека — только запасной вариант.
        for (k, a) in artists.prefix(11).enumerated() {
            if let full = try? await api.artist(a.id), let img = full.images.best(minWidth: 300) { artists[k].image = img }
        }
        let top = Set(artists.prefix(11).map { $0.id })
        let rankedTracks = tracks.sorted { a, b in
            let x = a.artists.contains { top.contains($0.id ?? "") }, y = b.artists.contains { top.contains($0.id ?? "") }
            return x && !y
        }
        let stats = YandexStats(at: Date(), total: refs.count, months: months, artists: artists, tracks: Array(rankedTracks.prefix(60)))
        write("yandex2", stats)
        return stats
    }

    /// «нояб.» для подписи столбика.
    static func monthLabel(_ key: String, full: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: key) else { return key }
        let out = DateFormatter()
        out.locale = Locale(identifier: Locale.preferredLanguages.first ?? "ru")
        out.setLocalizedDateFormatFromTemplate(full ? "LLLL" : "LLL")
        return out.string(from: d)
    }
}
