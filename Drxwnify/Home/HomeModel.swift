import Foundation

/// Что из ленты Spotify оставляет главная (`home/SpotifyHomeFilter.kt`): без «Альбомов с любимыми песнями»,
/// «Похожих», «Недавнего», «Пятничных новинок»; свои миксы — отдельным рядом.
enum SpotifyHomeFilter {
    private static let removed: [NSRegularExpression] = [
        "songs you like", "artists you follow", "favou?rite artists", "^more like", "recently played", "jump back in",
        "альбом.*(нрав|любим)", "(нрав|любим).*альбом", "подписан", "любим\\S* исполнител", "похож", "недавно",
        "^(слушать )?снова", "friday", "пятнич",
    ].map { try! NSRegularExpression(pattern: $0) }

    static func isRemovedSection(_ title: String?) -> Bool {
        guard let t = title?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return true }
        return removed.contains { ForYouRecommender.matches($0, t) }
    }

    private static let personalMix = try! NSRegularExpression(
        pattern: "daily mix|discover weekly|release radar|on repeat|repeat rewind|daylist|time capsule|blend|микс дня|открытия недели|радар новинок|на повторе|капсула времени",
        options: .caseInsensitive)
    private static let suffixMix = try! NSRegularExpression(pattern: "^(.+?)\\s+(mix|микс)$", options: .caseInsensitive)
    private static let prefixMix = try! NSRegularExpression(pattern: "^(mix|микс)\\s*[:\\-–—]?\\s+(.+)$", options: .caseInsensitive)

    static func isOwnMix(_ name: String, artists: [String], genres: [String]) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        if ForYouRecommender.matches(personalMix, n) { return true }
        func group(_ re: NSRegularExpression, _ i: Int) -> String? {
            guard let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)), let r = Range(m.range(at: i), in: n) else { return nil }
            return String(n[r])
        }
        guard let subject = (group(suffixMix, 1) ?? group(prefixMix, 2))?.trimmingCharacters(in: .whitespaces).lowercased(), !subject.isEmpty else { return false }
        return (artists + genres).contains { raw in
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return !key.isEmpty && (key == subject || (key.count >= 4 && subject.count >= 4 && (subject.contains(key) || key.contains(subject))))
        }
    }

    /// Плейлист Spotify — «под вкус»: чужой или личный микс; редакторские сборники уходят.
    static func isTasteBased(_ p: SpotifyHomeItem) -> Bool {
        guard (p.owner ?? "").caseInsensitiveCompare("Spotify") == .orderedSame else { return true }
        let n = p.name.lowercased()
        let personal = ["daily mix", "discover weekly", "release radar", "on repeat", "repeat rewind", "your time capsule", "time capsule",
                        "your top songs", "your summer rewind", "made for", "blend", "микс дня", "открытия недели", "радар новинок"]
        return p.madeFor != nil || personal.contains { n.contains($0) }
    }
}

/// Что слушает друг сейчас или слушал последним.
struct FriendListening: Identifiable, Hashable {
    var pubkey: String
    var name: String
    var avatar: String?
    var track: FriendsHub.TrackRef
    var now: Bool
    var at: Int64
    var id: String { pubkey }

    /// Сначала играющие сейчас, потом последний трек каждого за три дня (`friendsListening` на Android).
    static func list(_ hub: FriendsHub) -> [FriendListening] {
        let now = FriendsHub.nowMs()
        let me = hub.profile?.pubkey
        var out: [FriendListening] = []
        for f in hub.friends where f.pubkey != me {
            guard let d = hub.data[f.pubkey] else { continue }
            let name = d.name ?? (f.name.isEmpty ? String(f.pubkey.prefix(8)) : f.name)
            if let p = d.now, p.playing, now - p.at < 20 * 60_000 {
                out.append(FriendListening(pubkey: f.pubkey, name: name, avatar: d.avatar, track: p.track, now: true, at: p.at))
                continue
            }
            var candidates: [FriendsHub.TrackRef] = []
            if let h = d.history?.max(by: { $0.at < $1.at }) { candidates.append(h) }
            if let p = d.now { var t = p.track; t.at = p.at; candidates.append(t) }
            if let last = candidates.max(by: { $0.at < $1.at }), now - last.at < 3 * 86_400_000 {
                out.append(FriendListening(pubkey: f.pubkey, name: name, avatar: d.avatar, track: last, now: false, at: last.at))
            }
        }
        return Array(out.sorted { a, b in a.now != b.now ? a.now : a.at > b.at }.prefix(12))
    }
}

/// Данные главной (`viewmodels/HomeViewModel.kt`): «Для тебя», новинки и лента Spotify, свои миксы, главная новичка;
/// личные ряды — в `HomeFeed`.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var forYou: [SpotifyTrack]?
    @Published private(set) var newcomer: Bool
    @Published private(set) var starter: StarterPicks.Shown?
    @Published private(set) var newReleases: [SpotifyAlbum] = []
    @Published private(set) var spotifySections: [SpotifyHomeSection] = []
    @Published private(set) var mixes: [SpotifyHomeItem] = []
    @Published private(set) var loading = false
    /// Кубик крутится: первые треки радио ещё подбираются.
    @Published private(set) var starting = false

    private var taste: TasteData?
    private var loadedAt: Date?
    private var prepared: (ForYouRecommender.Session, [SpotifyTrack])?
    private var preparing = false
    private let defaults = UserDefaults.standard
    private static let retryDelays: [UInt64] = [4, 10, 25]

    init() {
        newcomer = UserDefaults.standard.bool(forKey: "home_newcomer")
        forYou = Self.savedForYou()
    }

    private static var forYouFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("for_you_last.json")
    }

    private static func savedForYou() -> [SpotifyTrack]? {
        guard let data = try? Data(contentsOf: forYouFile), let list = try? JSONDecoder().decode([SpotifyTrack].self, from: data), !list.isEmpty else { return nil }
        return list
    }

    func load(_ env: AppEnvironment, force: Bool = false) {
        if loading { return }
        if !force, let at = loadedAt, Date().timeIntervalSince(at) < 15 * 60 { return }
        loading = true
        loadedAt = Date()
        let api = env.spotify
        let database = env.database
        let hideExplicit = env.prefs.settings.get(PK.hideExplicit) ?? false
        let spotifyLinked = !(env.prefs.settings.get(PK.spotifySpDc) ?? "").isEmpty
        Task {
            let data = await TasteData.load(database: database, spotify: api)
            self.taste = data
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadForYou(data, api: api, hideExplicit: hideExplicit) }
                group.addTask { await HomeFeed.shared.refresh(data, api: api, hideExplicit: hideExplicit, force: force) }
                if spotifyLinked && !api.yandexIsSource {
                    group.addTask { await self.loadSpotifyHome(api) }
                }
            }
            await self.loadStarter(data, api: api, hideExplicit: hideExplicit)
            self.loading = false
        }
    }

    // MARK: - «Для тебя»

    private func loadForYou(_ data: TasteData, api: SpotifyAPI, hideExplicit: Bool) async {
        if newcomer { return }
        var built = await ForYouRecommender.build(data, api: api, hideExplicit: hideExplicit)
        // Сразу после запуска сеть или VPN часто ещё не поднялись: ещё несколько попыток.
        for wait in Self.retryDelays where built.isEmpty {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            built = await ForYouRecommender.build(data, api: api, hideExplicit: hideExplicit)
        }
        if !built.isEmpty || forYou == nil { forYou = built.isEmpty ? nil : built }
        if !built.isEmpty, let out = try? JSONEncoder().encode(built) { try? out.write(to: Self.forYouFile, options: .atomic) }
        prepared = nil
        prepareRadio(api: api, hideExplicit: hideExplicit)
    }

    private func newSession(api: SpotifyAPI, hideExplicit: Bool, excludeAlso: String? = nil) -> ForYouRecommender.Session? {
        guard let taste = taste else { return nil }
        // Обложки на странице не повторяются: радио приносит новое.
        return ForYouRecommender.Session(data: taste, api: api, hideExplicit: hideExplicit,
                                         exclude: (forYou ?? []).map { $0.id } + (excludeAlso.map { [$0] } ?? []))
    }

    private func prepareRadio(api: SpotifyAPI, hideExplicit: Bool) {
        guard !preparing, let session = newSession(api: api, hideExplicit: hideExplicit) else { return }
        preparing = true
        Task {
            let first = await session.next(6)
            if !first.isEmpty { self.prepared = (session, first) }
            self.preparing = false
        }
    }

    /// Тап по обложке: этот трек играет сразу, дальше — радио.
    func playFrom(_ start: SpotifyTrack, env: AppEnvironment) {
        let hideExplicit = env.prefs.settings.get(PK.hideExplicit) ?? false
        if newcomer, let s = starter { return playStarter(s, start: start, env: env) }
        let ready = prepared
        prepared = nil
        let session = ready?.0 ?? newSession(api: env.spotify, hideExplicit: hideExplicit, excludeAlso: start.id)
        prepareRadio(api: env.spotify, hideExplicit: hideExplicit)
        let tracks = [Track(start)] + (ready?.1 ?? []).filter { $0.id != start.id }.map { Track($0) }
        var origin: PlayerController.Origin = .album
        if let session = session { origin = .radio(ForYouRadio(session: session)) }
        env.player.play(tracks, title: L("for_you"), shuffled: false, origin: origin)
    }

    /// Кубик: свежие рекомендации (обычно уже подготовлены).
    func dice(_ env: AppEnvironment) {
        let hideExplicit = env.prefs.settings.get(PK.hideExplicit) ?? false
        if newcomer, let s = starter { return playStarter(s, start: nil, env: env) }
        if let ready = prepared {
            prepared = nil
            prepareRadio(api: env.spotify, hideExplicit: hideExplicit)
            env.player.play(ready.1.map { Track($0) }, title: L("for_you"), shuffled: false, origin: .radio(ForYouRadio(session: ready.0)))
            return
        }
        guard let session = newSession(api: env.spotify, hideExplicit: hideExplicit) else { return }
        starting = true
        Task {
            let first = await session.next(6)
            self.starting = false
            self.prepareRadio(api: env.spotify, hideExplicit: hideExplicit)
            guard !first.isEmpty else { return }
            env.player.play(first.map { Track($0) }, title: L("for_you"), shuffled: false, origin: .radio(ForYouRadio(session: session)))
        }
    }

    /// Радио новичка: стартовые подборки в новом порядке, выбранный трек первым.
    private func playStarter(_ s: StarterPicks.Shown, start: SpotifyTrack?, env: AppEnvironment) {
        var seen = Set<String>()
        let pool = (s.grid + s.genreRows.flatMap { $0.tracks } + s.artistRows.flatMap { $0.tracks }).shuffled().filter { $0.id != start?.id }
        let tracks = ((start.map { [$0] } ?? []) + pool).filter { seen.insert($0.id).inserted }
        guard !tracks.isEmpty else { return }
        env.player.play(tracks.map { Track($0) }, title: L("for_you"), shuffled: false, origin: .list)
    }

    // MARK: - Новичок

    private func loadStarter(_ data: TasteData, api: SpotifyAPI, hideExplicit: Bool) async {
        var liked = Set<String>()
        for l in data.liked { liked.insert(RadioKeys.trackKey(l.artist, l.title)) }
        for t in data.account.tracks { liked.insert(RadioKeys.trackKey(t.artists.first?.name ?? "", t.name)) }
        var followed = Set<String>()
        for f in data.followed { followed.insert(RadioKeys.norm(f.name)) }
        for a in data.account.artists { followed.insert(RadioKeys.norm(a)) }
        let isNewcomer = StarterPicks.isNewcomer(plays: data.playCount, liked: liked.count, followed: followed.count)
        let was = newcomer
        newcomer = isNewcomer
        defaults.set(isNewcomer, forKey: "home_newcomer")
        if was && !isNewcomer { await loadForYou(data, api: api, hideExplicit: hideExplicit) }
        guard isNewcomer else { starter = nil; return }
        let shown = await StarterPicks.build(api: api, hideExplicit: hideExplicit)
        starter = shown
        if let shown = shown {
            forYou = await withOwnPicks(shown.grid, share: StarterPicks.personalShare(plays: data.playCount), data: data, api: api, hideExplicit: hideExplicit)
        }
    }

    /// Доля квадратов сайта заменяется своими рекомендациями, равномерно по сетке.
    private func withOwnPicks(_ site: [SpotifyTrack], share: Double, data: TasteData, api: SpotifyAPI, hideExplicit: Bool) async -> [SpotifyTrack] {
        let wanted = Int((Double(site.count) * share).rounded())
        guard wanted > 0 else { return site }
        let own = await ForYouRecommender.Session(data: data, api: api, hideExplicit: hideExplicit, exclude: site.map { $0.id }).next(wanted)
        guard !own.isEmpty else { return site }
        var out = site
        let step = Double(site.count) / Double(own.count)
        for (i, t) in own.enumerated() {
            let at = min(out.count - 1, max(0, Int((Double(i) + 0.5) * step)))
            out[at] = t
        }
        return out
    }

    // MARK: - Spotify

    /// Страница из 50, где Spotify позволяет, иначе обычные 20.
    private static func firstReleases(_ api: SpotifyAPI) async -> SpotifyPaging<SpotifyAlbum>? {
        if let page = try? await api.newReleases(limit: 50) { return page }
        return try? await api.newReleases(limit: 20)
    }

    /// Лента Spotify на языке приложения, без разделов, которые приложение делает лучше само; свои миксы — одним рядом.
    private func loadSpotifyHome(_ api: SpotifyAPI) async {
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        async let releasesTask: SpotifyPaging<SpotifyAlbum>? = Self.firstReleases(api)
        async let homeTask: SpotifyHomeFeed? = try? await api.home(sectionItemsLimit: 20, language: language)
        if var first = await releasesTask {
            if first.total > first.items.count, let more = try? await api.newReleases(limit: 50, offset: first.items.count) {
                first.items += more.items
            }
            // Лента выдаёт и перевыложенные старые альбомы (новый id, старая дата), и двойники.
            let cutoff = ISO8601DateFormatter.string(from: Date().addingTimeInterval(-90 * 86400), timeZone: .current, formatOptions: [.withFullDate])
            var seen = Set<String>()
            newReleases = first.items.filter { a in
                let date = String((a.releaseDate ?? "").prefix(10))
                let key = a.name.trimmingCharacters(in: .whitespaces).lowercased() + "|" + (a.artists.first?.name.lowercased() ?? "")
                return (date.isEmpty || date >= cutoff) && seen.insert(key).inserted
            }
        }
        guard let home = await homeTask else { return }
        let feed = HomeFeed.shared.feed
        let artists = feed?.favoriteArtists ?? []
        let genres = feed?.genres ?? []
        var sections: [SpotifyHomeSection] = []
        var mixSeen = Set<String>()
        var mixList: [SpotifyHomeItem] = []
        for raw in home.sections where !SpotifyHomeFilter.isRemovedSection(raw.title) {
            let spotifyMade = raw.items.filter { $0.kind == .playlist && ($0.owner ?? "").caseInsensitiveCompare("Spotify") == .orderedSame }
            for p in spotifyMade where SpotifyHomeFilter.isOwnMix(p.name, artists: artists, genres: genres) && mixSeen.insert(p.id).inserted {
                mixList.append(p)
            }
            var rest = raw
            rest.items = raw.items.filter { !($0.kind == .playlist && ($0.owner ?? "").caseInsensitiveCompare("Spotify") == .orderedSame) }
                .filter { $0.kind != .playlist || SpotifyHomeFilter.isTasteBased($0) }
            if !rest.items.isEmpty { sections.append(rest) }
        }
        spotifySections = sections
        mixes = mixList
    }
}
