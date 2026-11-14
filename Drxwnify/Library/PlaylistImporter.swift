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

    /// Разбор вставленного текста: строки треков и ссылки (Spotify, Яндекс Музыка, SoundCloud).
    /// Без названия плейлист называется как источник по первой ссылке (Android 2.3.0), иначе «Импорт <дата>»;
    /// несколько ссылок без строк и без названия — по плейлисту на ссылку, каждый со своим названием.
    static func parse(_ text: String, name: String, existing: String?, env: AppEnvironment) async -> [Job] {
        var lines: [String] = []
        var links: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("://") || line.hasPrefix("open.spotify") || line.hasPrefix("soundcloud.com") || line.hasPrefix("music.yandex") {
                let link = line.hasPrefix("http") ? line : "https://" + line
                if !links.contains(link) { links.append(link) }
            } else {
                lines.append(line)
            }
        }
        let blank = name.trimmingCharacters(in: .whitespaces).isEmpty && existing == nil
        if blank && links.count > 1 && lines.isEmpty {
            var jobs: [Job] = []
            for link in links {
                var job = Job(name: "", existing: nil)
                await read(link, into: &job, env: env)
                job.name = await linkTitle(link, env: env) ?? defaultName()
                jobs.append(job)
            }
            return jobs
        }
        var main = Job(name: name, existing: existing)
        for link in links { await read(link, into: &main, env: env) }
        main.items += lines.map(item)
        if blank {
            var title: String?
            for link in links where title == nil { title = await linkTitle(link, env: env) }
            main.name = title ?? defaultName()
        }
        return [main]
    }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Locale.preferredLanguages.first ?? "ru")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return L("import_default_name", f.string(from: Date()))
    }

    /// Треки по одной ссылке.
    private static func read(_ link: String, into job: inout Job, env: AppEnvironment) async {
        if link.contains("soundcloud.com"), let sc = env.player.audioEngine.soundCloud {
            job.items += await sc.importLink(link)
            return
        }
        if YandexIds.isLink(link) {
            guard let y = env.spotify.yandex, let id = try? await y.idOfLink(link) else { return }
            if case .album? = YandexIds.parseLink(link) {
                if let a = try? await env.spotify.album(id) { job.ready += a.tracks.map { Track($0, album: a.simple) } }
            } else {
                job.ready += await spotifyPlaylist(id, api: env.spotify)
            }
            return
        }
        guard let url = URL(string: link), let t = AppLinks.parse(url) else { return }
        switch t.kind {
        case .playlist:
            job.ready += await spotifyPlaylist(t.id, api: env.spotify)
        case .album:
            if let a = try? await env.spotify.album(t.id) { job.ready += a.tracks.map { Track($0, album: a.simple) } }
        case .track:
            if let s = try? await env.spotify.track(t.id) { job.ready.append(Track(s)) }
        case .artist:
            break
        }
    }

    /// Название плейлиста или альбома по ссылке, как его называет сам сервис; nil — неизвестно.
    static func linkTitle(_ link: String, env: AppEnvironment) async -> String? {
        if YandexIds.isLink(link) {
            guard let y = env.spotify.yandex, let id = try? await y.idOfLink(link) else { return nil }
            if case .album? = YandexIds.parseLink(link) { return try? await env.spotify.album(id).name }
            return try? await env.spotify.playlist(id).name
        }
        guard let url = URL(string: link), let t = AppLinks.parse(url) else { return nil }
        switch t.kind {
        case .playlist: return try? await env.spotify.playlist(t.id).name
        case .album: return try? await env.spotify.album(t.id).name
        default: return nil
        }
    }

    /// Можно ли прочитать ссылку (для подсказки «название возьмём по ссылке»).
    static func isPlaylistLink(_ line: String) -> Bool {
        let l = line.lowercased()
        return (l.contains("open.spotify.com/") && (l.contains("/playlist/") || l.contains("/album/")))
            || l.contains("soundcloud.com/") || YandexIds.parseLink(line.hasPrefix("http") ? line : "https://" + line) != nil
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
