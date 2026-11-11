import Foundation

/// «Знакомство с жанром» (`genre/GenrePlaylists.kt`, HOME-010): 15 треков, лучше всего описывающих жанр, по тапу на тег.
///
/// Берутся из Last.fm: самые слушаемые треки жанра, сверенные с его же топом артистов (мем-тег ставит поп-песню первой
/// в «deathcore» — её артиста нет среди артистов deathcore, и она уходит). Сначала по одному треку на артиста.
/// Каждый ищется в каталоге ради обложки и звука; список держится неделю.
actor GenrePlaylists {
    static let shared = GenrePlaylists()
    static let size = 15
    private static let ttl: Double = 7 * 24 * 3600

    private struct Saved: Codable { var at: Double; var tracks: [SpotifyTrack] }
    private struct Artists: Codable { var at: Double; var names: [String] }

    private var memory: [String: Saved] = [:]
    private var artistsMemory: [String: Artists] = [:]
    weak var api: SpotifyAPI?

    func configure(_ api: SpotifyAPI) { self.api = api }

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("genre_playlists")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func safe(_ tag: String) -> String {
        tag.replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
    }

    /// Тег, под которым жанр знает Last.fm.
    static func lastFmTag(_ genre: String) -> String {
        switch genre.trimmingCharacters(in: .whitespaces).lowercased() {
        case "r&b": return "rnb"
        case "electronic dance": return "edm"
        case let g: return g
        }
    }

    /// Треки жанра: сохранённые, если свежие, иначе собранные заново (несколько секунд).
    func tracks(_ genre: String, force: Bool = false) async throws -> [SpotifyTrack] {
        let tag = Self.lastFmTag(genre)
        let file = Self.dir.appendingPathComponent(Self.safe(tag) + ".json")
        let now = Date().timeIntervalSince1970
        if !force {
            var saved = memory[tag]
            if saved == nil, let data = try? Data(contentsOf: file) { saved = try? JSONDecoder().decode(Saved.self, from: data) }
            if let s = saved, now - s.at < Self.ttl, !s.tracks.isEmpty { memory[tag] = s; return s.tracks }
        }
        let built = try await build(tag, genre)
        if !built.isEmpty {
            let s = Saved(at: now, tracks: built)
            memory[tag] = s
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: file, options: .atomic) }
        }
        return built
    }

    /// Самые отмеченные жанром артисты Last.fm (до 250), один запрос на жанр в неделю.
    func topArtistNamesOf(_ genre: String) async -> [String] {
        let tag = Self.lastFmTag(genre)
        let file = Self.dir.appendingPathComponent("artists_" + Self.safe(tag) + ".json")
        let now = Date().timeIntervalSince1970
        var kept = artistsMemory[tag]
        if kept == nil, let data = try? Data(contentsOf: file) { kept = try? JSONDecoder().decode(Artists.self, from: data) }
        if let k = kept, now - k.at < Self.ttl, !k.names.isEmpty { artistsMemory[tag] = k; return k.names }
        guard let list = try? await Self.lastFm("tag.gettopartists", tag, 250, "topartists", "artist") else { return kept?.names ?? [] }
        let names = list.compactMap { $0.str("name") }.filter { !$0.isEmpty }
        if !names.isEmpty {
            let fresh = Artists(at: now, names: names)
            artistsMemory[tag] = fresh
            if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: file, options: .atomic) }
        }
        return names
    }

    func topArtistsOf(_ genre: String) async -> Set<String> {
        Set(await topArtistNamesOf(genre).map(RadioKeys.norm))
    }

    private struct Candidate { var artist: String; var title: String }

    private func build(_ tag: String, _ genre: String) async throws -> [SpotifyTrack] {
        guard let api = api else { throw HomeError("catalog unavailable") }
        async let topTask = Self.lastFm("tag.gettoptracks", tag, 150, "tracks", "track")
        let artistsOfGenre = await topArtistsOf(genre)
        let family = Genres.family(genre).lowercased()
        func belongs(_ artist: String) -> Bool {
            artistsOfGenre.contains(RadioKeys.norm(artist)) ||
                Genres.shared.cached(artist).contains { Genres.family($0).lowercased() == family || $0.caseInsensitiveCompare(genre) == .orderedSame }
        }
        var seenKeys = Set<String>()
        let top: [JSONObject] = try await topTask
        let ranked: [Candidate] = top.compactMap { o -> Candidate? in
            guard let title = o.str("name"), !title.isEmpty, let artist = o.obj("artist")?.str("name"), !artist.isEmpty else { return nil }
            return Candidate(artist: artist, title: title)
        }.filter { c in
            guard belongs(c.artist) else { return false }
            let base = c.title.components(separatedBy: " (").first ?? c.title
            return seenKeys.insert(RadioKeys.norm(c.artist) + "|" + RadioKeys.norm(base)).inserted
        }
        // По одному на артиста в порядке Last.fm, потом вторые.
        var perArtist: [String: Int] = [:]
        var first: [Candidate] = []
        var second: [Candidate] = []
        for c in ranked {
            let n = (perArtist[RadioKeys.norm(c.artist)] ?? 0) + 1
            perArtist[RadioKeys.norm(c.artist)] = n
            if n == 1 { first.append(c) } else if n == 2 { second.append(c) }
        }
        let order = first + second
        var found: [SpotifyTrack] = []
        var index = 0
        while found.count < Self.size && index < order.count {
            let batch = Array(order[index..<min(order.count, index + (Self.size - found.count) + 3)])
            index += batch.count
            let results: [SpotifyTrack?] = await withTaskGroup(of: (Int, SpotifyTrack?).self) { group in
                for (i, c) in batch.enumerated() {
                    group.addTask { (i, await Self.lookUp(c.artist, c.title, api)) }
                }
                var out = [SpotifyTrack?](repeating: nil, count: batch.count)
                for await (i, t) in group { out[i] = t }
                return out
            }
            for t in results.compactMap({ $0 }) where found.count < Self.size && !found.contains(where: { $0.id == t.id }) {
                found.append(t)
            }
        }
        return found
    }

    private static func cut(_ title: String) -> String {
        var t = title
        if let r = t.range(of: " (") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        return RadioKeys.norm(t)
    }

    private static func lookUp(_ artist: String, _ title: String, _ api: SpotifyAPI) async -> SpotifyTrack? {
        let wanted = cut(title)
        let a = RadioKeys.norm(artist)
        guard let r = try? await api.search("\(artist) \(title)", limit: 5) else { return nil }
        return r.tracks.first { t in
            let artistOk = t.artists.contains { x in
                let n = RadioKeys.norm(x.name)
                return n == a || (n.count >= 3 && (a.contains(n) || n.contains(a)))
            }
            let candidate = cut(t.name)
            return artistOk && !t.id.isEmpty && !t.isLocal && (candidate == wanted || candidate.hasPrefix(wanted) || wanted.hasPrefix(candidate))
        }
    }

    private static func lastFm(_ method: String, _ tag: String, _ limit: Int, _ root: String, _ item: String) async throws -> [JSONObject] {
        var c = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        c.queryItems = [
            URLQueryItem(name: "method", value: method), URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "api_key", value: Genres.apiKey),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = c.url else { return [] }
        let r = try await HTTP.get(url, timeout: 15)
        guard r.isSuccess else { throw HomeError("Last.fm \(r.status)") }
        return JSON.object(r.data)?.obj(root)?.objects(item) ?? []
    }
}

/// Ошибка главной с текстом для экрана.
struct HomeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
