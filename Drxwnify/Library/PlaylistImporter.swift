import Foundation

/// Импорт плейлистов (Android 1.3.0–2.2.0, `PlaylistImporter.kt`): строки «Исполнитель - Название», ссылки Spotify/SoundCloud,
/// лайки и плейлисты профиля SoundCloud. Каждый трек ищется в каталоге с проверкой совпадения, 6 параллельно, ≤ 12 с на трек.
/// Ничего не скачивается: получается свой плейлист.
final class PlaylistImporter: ObservableObject {
    struct Item: Hashable {
        var artist: String
        var title: String
        var durationMs: Int = 0
        var label: String { artist.isEmpty ? title : "\(artist) - \(title)" }
    }

    /// Что импортировать в один плейлист.
    struct Job {
        var name: String
        /// id своего плейлиста, если дополняем существующий.
        var existing: String?
        var items: [Item] = []
        /// Уже готовые треки каталога (ссылки на плейлист/альбом Spotify).
        var ready: [Track] = []
    }

    static let shared = PlaylistImporter()

    @Published private(set) var running = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var found = 0
    @Published private(set) var notFound: [String] = []
    @Published private(set) var current = ""
    @Published private(set) var lastPlaylist: String?
    private var cancelled = false

    private static let parallel = 6
    private static let perTrack: UInt64 = 12

    func cancel() { cancelled = true }

    func run(_ jobs: [Job], env: AppEnvironment) {
        guard !running, !jobs.isEmpty else { return }
        running = true
        cancelled = false
        done = 0
        found = 0
        notFound = []
        total = jobs.reduce(0) { $0 + $1.items.count + $1.ready.count }
        let api = env.spotify, library = env.library
        Task {
            for job in jobs {
                if self.cancelled { break }
                await MainActor.run { self.current = job.name }
                var tracks: [Track?] = Array(repeating: nil, count: job.items.count)
                var i = 0
                while i < job.items.count && !self.cancelled {
                    let range = i..<min(i + Self.parallel, job.items.count)
                    await withTaskGroup(of: (Int, Track?).self) { group in
                        for k in range {
                            let item = job.items[k]
                            group.addTask { (k, await Self.match(item, api: api)) }
                        }
                        for await (k, t) in group {
                            tracks[k] = t
                            let label = job.items[k].label
                            await MainActor.run {
                                self.done += 1
                                if t != nil { self.found += 1 } else { self.notFound.append(label) }
                            }
                        }
                    }
                    i = range.upperBound
                }
                var list = job.ready + tracks.compactMap { $0 }
                var seen = Set<String>()
                list = list.filter { seen.insert($0.id).inserted }
                await MainActor.run {
                    self.done += job.ready.count
                    self.found += job.ready.count
                    guard !list.isEmpty else { return }
                    let id = job.existing ?? library.createPlaylist(name: job.name)
                    // Дополняем: то, что уже есть в плейлисте, второй раз не кладём.
                    let have = library.contained(in: id, list.map { $0.id })
                    library.add(list.filter { !have.contains($0.id) }, to: id)
                    self.lastPlaylist = id
                }
            }
            await MainActor.run {
                self.running = false
                self.current = ""
            }
        }
    }

    /// Лучший трек каталога для строки: поиск «артист название», проверка `FuzzyTrackMatch`.
    static func match(_ item: Item, api: SpotifyAPI) async -> Track? {
        await withTaskGroup(of: Track??.self) { group in
            group.addTask {
                let q = [item.artist, item.title].filter { !$0.isEmpty }.joined(separator: " ")
                guard let r = try? await api.search(q, limit: 10) else { return .some(nil) }
                let ranked = FuzzyTrackMatch.ranked(
                    artist: item.artist.isEmpty ? nil : item.artist, title: item.title,
                    durationSec: item.durationMs > 0 ? item.durationMs / 1000 : nil,
                    candidates: r.tracks.map { FuzzyTrackMatch.Candidate(id: $0.id, title: $0.name, artists: $0.artists.map { $0.name },
                                                                          durationSec: $0.durationMs > 0 ? $0.durationMs / 1000 : nil) })
                // Без исполнителя — первый результат с подходящим названием.
                guard let best = ranked.first, let t = r.tracks.first(where: { $0.id == best.id }) else { return .some(nil) }
                return .some(Track(t))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: perTrack * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Разбор вставленного текста: строки треков и ссылки. Ссылки на плейлисты становятся своими задачами.
    static func parse(_ text: String, name: String, existing: String?, env: AppEnvironment) async -> [Job] {
        var main = Job(name: name, existing: existing)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("://") || line.hasPrefix("open.spotify") || line.hasPrefix("soundcloud.com") {
                let link = line.hasPrefix("http") ? line : "https://" + line
                if link.contains("soundcloud.com"), let sc = env.player.audioEngine.soundCloud {
                    main.items += await sc.importLink(link)
                } else if let url = URL(string: link), let t = AppLinks.parse(url) {
                    switch t.kind {
                    case .playlist:
                        main.ready += await spotifyPlaylist(t.id, api: env.spotify)
                    case .album:
                        if let a = try? await env.spotify.album(t.id) { main.ready += a.tracks.map { Track($0, album: a.simple) } }
                    case .track:
                        if let s = try? await env.spotify.track(t.id) { main.ready.append(Track(s)) }
                    case .artist:
                        break
                    }
                }
                continue
            }
            main.items.append(item(line))
        }
        return [main]
    }

    /// «Исполнитель - Название» (а также «—», «–»); без тире — только название. Нумерация «1.» отбрасывается.
    static func item(_ line: String) -> Item {
        var s = line
        if let r = s.range(of: "^\\s*\\d+[.)]\\s+", options: .regularExpression) { s.removeSubrange(r) }
        for sep in [" - ", " — ", " – "] {
            if let r = s.range(of: sep) {
                return Item(artist: String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                            title: String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return Item(artist: "", title: s)
    }

    private static func spotifyPlaylist(_ id: String, api: SpotifyAPI) async -> [Track] {
        var out: [Track] = []
        var offset = 0
        while offset < 2000 {
            guard let page = try? await api.playlistTracks(id, limit: 100, offset: offset) else { break }
            out += page.items.map { Track($0.track) }
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total { break }
        }
        return out
    }
}
