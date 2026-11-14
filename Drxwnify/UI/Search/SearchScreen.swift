import SwiftUI
import GRDB

/// Поиск по каталогу Spotify (UI этапа 5): строка поиска, история, фильтры-чипы, результаты по разделам.
struct SearchScreen: View {
    enum Filter: String, CaseIterable {
        case all, songs, artists, albums, playlists

        var title: String {
            switch self {
            case .all: return L("filter_all")
            case .songs: return L("songs")
            case .artists: return L("artists")
            case .albums: return L("albums")
            case .playlists: return L("playlists")
            }
        }
    }

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = SearchModel()
    @State private var filter = Filter.all
    @State private var confirmClear = false
    /// Жанр, открытый с плитки. Один скрытый переход на весь список: `NavigationLink` в каждой плитке
    /// на iOS 26 рисует шеврон «›» справа от каждой плитки.
    @State private var openGenre: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                history
            } else {
                chips
                results
            }
        }
        .rootTitle(L("search")) { TopBarIcons() }
        .onAppear { model.attach(env) }
        .onReceive(env.$debugSearch.compactMap { $0 }) { q in
            model.attach(env)
            model.query = q
            model.submit()
            env.debugSearch = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L("ios_search_hint"), text: $model.query, onCommit: { model.submit() })
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !model.query.isEmpty {
                Button(action: { model.query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
            sourceMenu
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.16)))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// «Где искать» (Android `SearchSourceButton`): библиотека, Spotify, Яндекс и ВК (если подключены), YouTube Music.
    private var sourceMenu: some View {
        Menu {
            Picker(L("search_source_picker"), selection: $model.source) {
                ForEach(model.available(env), id: \.self) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
        } label: {
            Image(systemName: model.source.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(model.source.tint)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("search_source_picker"))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { filter = f } }) {
                        Text(f.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .foregroundColor(filter == f ? Color(.systemBackground) : .primary)
                            .background(Capsule().fill(filter == f ? Color.accentColor : Color.secondary.opacity(0.2)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    /// Без запроса — как на Android: история (⏱ запрос ✕ ↖), под ней жанры плитками.
    private var history: some View {
        List {
            if !model.history.isEmpty {
                HStack {
                    Text(L("search_history")).font(.headline)
                    Spacer()
                    Button(action: { confirmClear = true }) { Image(systemName: "trash").foregroundColor(.secondary) }
                        .buttonStyle(BorderlessButtonStyle())
                }
                .listRowBackground(Color.clear)
                ForEach(model.history.prefix(12), id: \.self) { q in
                    HStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
                        Text(q).foregroundColor(.primary).lineLimit(1)
                        Spacer()
                        Button(action: { model.removeHistory(q) }) {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary).frame(width: 30, height: 30)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        Button(action: { model.query = q }) {
                            Image(systemName: "arrow.up.left").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary).frame(width: 30, height: 30)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.query = q; model.submit() }
                    .themedRow()
                }
            }
            Text(L("ios_search_genres")).font(.headline).padding(.top, 10).listRowBackground(Color.clear)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Self.genres, id: \.0) { g, color in
                    Button(action: { openGenre = g }) {
                        Text(g).font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .bottomLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
            .listRowBackground(Color.clear)
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .background(NavigationLink(destination: GenreScreen(genre: openGenre ?? ""),
                                   isActive: Binding(get: { openGenre != nil }, set: { if !$0 { openGenre = nil } })) { EmptyView() }
                        .opacity(0))
        .alert(isPresented: $confirmClear) {
            Alert(title: Text(L("clear_search_history")), message: Text(L("clear_search_history_confirm")),
                  primaryButton: .destructive(Text(L("clear_search_history"))) { model.clearHistory() },
                  secondaryButton: .cancel(Text(L("cancel"))))
        }
    }

    private static let genres: [(String, Color)] = [
        ("Rock", Color(red: 0.75, green: 0.22, blue: 0.2)), ("Metal", Color(red: 0.3, green: 0.3, blue: 0.34)),
        ("Hip-Hop", Color(red: 0.85, green: 0.5, blue: 0.1)), ("Electronic", Color(red: 0.2, green: 0.45, blue: 0.85)),
        ("Post-Punk", Color(red: 0.45, green: 0.25, blue: 0.6)), ("Indie", Color(red: 0.15, green: 0.6, blue: 0.45)),
        ("Shoegaze", Color(red: 0.8, green: 0.4, blue: 0.55)), ("Metalcore", Color(red: 0.55, green: 0.15, blue: 0.15)),
        ("Pop", Color(red: 0.9, green: 0.35, blue: 0.6)), ("Ambient", Color(red: 0.25, green: 0.55, blue: 0.65)),
        ("Jazz", Color(red: 0.6, green: 0.45, blue: 0.2)), ("Breakcore", Color(red: 0.5, green: 0.2, blue: 0.75)),
    ]

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).foregroundColor(.accentColor).padding(.top, 10)
            .listRowBackground(Color.clear)
            .listRowSeparatorHiddenCompat()
    }

    private var results: some View {
        List {
            if model.source == .library, let l = model.local {
                if l.isEmpty {
                    Text(L("no_results_found")).foregroundColor(.secondary).listRowBackground(Color.clear)
                }
                if (filter == .all || filter == .songs) && !l.tracks.isEmpty {
                    sectionTitle(L("songs"))
                    let list = filter == .all ? Array(l.tracks.prefix(8)) : l.tracks
                    ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t, context: list, index: i, queueTitle: model.submitted)
                    }
                }
                if (filter == .all || filter == .artists) && !l.artists.isEmpty {
                    sectionTitle(L("artists"))
                    ForEach(l.artists) { a in
                        NavigationLink(destination: LocalArtistScreen(artist: a)) {
                            entry(a.thumbnailUrl, a.name, LPlural("n_song", a.songCount), circle: true)
                        }
                        .themedRow()
                    }
                }
                if (filter == .all || filter == .playlists) && !l.playlists.isEmpty {
                    sectionTitle(L("playlists"))
                    ForEach(l.playlists) { p in
                        NavigationLink(destination: LocalPlaylistScreen(playlist: p)) {
                            entry(p.thumbnailUrl ?? p.thumbnails.first, p.name, LPlural("n_song", p.songCount))
                        }
                        .themedRow()
                    }
                }
            } else if let r = model.result {
                if r.isEmpty {
                    Text(L("no_results_found")).foregroundColor(.secondary).listRowBackground(Color.clear)
                }
                let short = filter == .all
                // «Лучший результат» — первый исполнитель, если его имя совпадает с запросом, иначе первый трек.
                if short, let top = topArtist(r) {
                    sectionTitle(L("ios_top_result"))
                    NavigationLink(destination: SpotifyArtistScreen(artistId: top.id, name: top.name)) {
                        HStack(spacing: 14) {
                            ArtworkView(url: top.images.best(minWidth: 300), size: 72, circle: true, placeholderSymbol: "person.fill")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(top.name).font(.title3.weight(.bold)).lineLimit(1)
                                Text(L("ios_artist")).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .themedRow()
                }
                if (filter == .all || filter == .songs) && !r.tracks.isEmpty {
                    sectionTitle(L("songs"))
                    let list = short ? Array(r.tracks.prefix(5)) : r.tracks
                    ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                        SpotifyTrackRow(track: t, context: list, index: i, queueTitle: model.submitted)
                    }
                }
                if (filter == .all || filter == .artists) && !r.artists.isEmpty {
                    sectionTitle(L("artists"))
                    if short {
                        SpotifyShelf(items: Array(r.artists.prefix(12)), imageUrl: { $0.images.best(minWidth: 250) },
                                     title: { $0.name }, subtitle: { _ in nil }, circle: true) { SpotifyArtistScreen(artistId: $0.id, name: $0.name) }
                    } else {
                        ForEach(r.artists) { a in
                            NavigationLink(destination: SpotifyArtistScreen(artistId: a.id, name: a.name)) {
                                entry(a.images.best(minWidth: 150), a.name, L("ios_artist"), circle: true)
                            }
                            .themedRow()
                        }
                    }
                }
                if (filter == .all || filter == .albums) && !r.albums.isEmpty {
                    sectionTitle(L("albums"))
                    if short {
                        SpotifyShelf(items: Array(r.albums.prefix(12)), imageUrl: { $0.images.best(minWidth: 250) },
                                     title: { $0.name }, subtitle: { $0.artistNames }) { SpotifyAlbumScreen(albumId: $0.id, name: $0.name) }
                    } else {
                        ForEach(r.albums) { a in
                            NavigationLink(destination: SpotifyAlbumScreen(albumId: a.id, name: a.name)) {
                                entry(a.images.best(minWidth: 150), a.name,
                                      [a.artistNames, a.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            }
                            .themedRow()
                        }
                    }
                }
                if (filter == .all || filter == .playlists) && !r.playlists.isEmpty {
                    sectionTitle(L("playlists"))
                    ForEach(short ? Array(r.playlists.prefix(4)) : r.playlists) { p in
                        NavigationLink(destination: SpotifyPlaylistScreen(playlistId: p.id, name: p.name,
                                                                          imageUrl: p.images.best(minWidth: 300))) {
                            entry(p.images.best(minWidth: 150), p.name, p.owner?.displayName ?? L("ios_playlist"))
                        }
                        .themedRow()
                    }
                }
            }
            LoadStatusRow(isLoading: model.isLoading, error: model.error, retry: { model.search(force: true) })
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
    }

    private func topArtist(_ r: SpotifySearchResult) -> SpotifyArtist? {
        guard let a = r.artists.first else { return nil }
        let q = model.submitted.lowercased().trimmingCharacters(in: .whitespaces)
        let n = a.name.lowercased()
        return (n == q || q.hasPrefix(n) || n.hasPrefix(q)) ? a : nil
    }

    private func entry(_ image: String?, _ title: String, _ subtitle: String, circle: Bool = false) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: image, size: 50, cornerRadius: 6, circle: circle, placeholderSymbol: circle ? "person.fill" : "music.note.list")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

final class SearchModel: ObservableObject {
    /// Где искать (Android `SearchSource`; «эксперимент по источникам» на iOS не перенесён).
    enum Source: String, CaseIterable {
        case library, spotify, yandex, vk, youtube

        var title: String {
            switch self {
            case .library: return L("search_source_library")
            case .spotify: return L("search_source_spotify")
            case .yandex: return L("search_source_yandex")
            case .vk: return L("vk_music_name")
            case .youtube: return L("search_source_youtube")
            }
        }

        var symbol: String {
            switch self {
            case .library: return "music.note.house"
            case .spotify: return "dot.radiowaves.left.and.right"
            case .yandex: return "music.note"
            case .vk: return "person.2.wave.2"
            case .youtube: return "play.rectangle"
            }
        }

        var tint: Color {
            switch self {
            case .library: return .secondary
            case .spotify: return Color(red: 0.12, green: 0.84, blue: 0.38)
            case .yandex: return Color(red: 1, green: 0.8, blue: 0)
            case .vk: return Color(red: 0.0, green: 0.47, blue: 1)
            case .youtube: return Color(red: 1, green: 0.18, blue: 0.18)
            }
        }
    }

    struct LocalResult {
        var tracks: [Track] = []
        var artists: [LocalArtist] = []
        var playlists: [LocalPlaylist] = []
        var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && playlists.isEmpty }
    }

    @Published var source: Source = Source(rawValue: UserDefaults.standard.string(forKey: "searchSource") ?? "") ?? .spotify {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: "searchSource")
            result = nil
            local = nil
            search(force: true)
        }
    }
    @Published private(set) var local: LocalResult?
    private lazy var youtube = YouTubeProvider()

    /// Яндекс и ВК — только когда аккаунт подключён (как на Android).
    func available(_ env: AppEnvironment) -> [Source] {
        Source.allCases.filter {
            switch $0 {
            case .yandex: return env.spotify.yandex != nil
            case .vk: return env.spotify.vkCatalog != nil
            default: return true
            }
        }
    }

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published private(set) var result: SpotifySearchResult?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var history: [String] = []
    /// Запрос, по которому показаны результаты.
    private(set) var submitted = ""

    private weak var env: AppEnvironment?
    private var task: Task<Void, Never>?

    func attach(_ env: AppEnvironment) {
        if self.env == nil {
            self.env = env
            loadHistory()
        }
        if !available(env).contains(source) { source = .spotify }
    }

    /// Ссылка в строке поиска (Android 2.1.3): Spotify, Яндекс, Drxwnify — открыть экран; YouTube — искать по названию ролика.
    private func handleLink(_ q: String) -> Bool {
        guard q.contains("://") || q.hasPrefix("www.") || q.hasPrefix("youtu"), let url = URL(string: q.hasPrefix("http") || q.contains("://") ? q : "https://" + q) else { return false }
        if let t = AppLinks.parse(url) {
            DispatchQueue.main.async { self.env?.linkTarget = t; self.query = "" }
            return true
        }
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return false }
        var c = URLComponents(string: "https://www.youtube.com/oembed")
        c?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        guard let api = c?.url else { return false }
        isLoading = true
        URLSession.shared.dataTask(with: api) { [weak self] data, _, _ in
            let o = data.flatMap { JSON.object($0) }
            var title = o?.str("title") ?? ""
            let author = (o?.str("author_name") ?? "").replacingOccurrences(of: " - Topic", with: "")
            if !author.isEmpty && !title.lowercased().contains(author.lowercased()) { title = author + " " + title }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                if title.isEmpty { self.error = L("ios_link_not_recognized") } else { self.query = title; self.submit() }
            }
        }.resume()
        return true
    }

    private func scheduleSearch() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if handleLink(q) { return }
        if q.isEmpty {
            result = nil
            local = nil
            error = nil
            isLoading = false
            return
        }
        task = Task { [weak self] in
            // Ждём паузу в наборе.
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            await self?.run(q)
        }
    }

    /// Ввод завершён: искать сразу и запомнить запрос.
    func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        saveHistory(q)
        search(force: true)
    }

    func search(force: Bool) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        task = Task { [weak self] in await self?.run(q) }
    }

    private func run(_ q: String) async {
        guard let env = env else { return }
        await MainActor.run {
            self.isLoading = true
            self.error = nil
        }
        do {
            let src = await MainActor.run { self.source }
            if src == .library {
                let lib = env.library
                let n = q.lowercased()
                var l = LocalResult()
                l.tracks = lib.songs(sort: .playTime, descending: true)
                    .filter { $0.title.lowercased().contains(n) || $0.artistNames.lowercased().contains(n) || ($0.albumName ?? "").lowercased().contains(n) }
                l.artists = lib.artists().filter { $0.name.lowercased().contains(n) }
                l.playlists = lib.playlists().filter { $0.name.lowercased().contains(n) }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.local = l
                    self.submitted = q
                    self.isLoading = false
                }
                return
            }
            let r: SpotifySearchResult
            switch src {
            case .library, .spotify: r = try await env.spotify.searchIn(.SPOTIFY, q, limit: 20)
            case .yandex: r = try await env.spotify.searchIn(.YANDEX, q, limit: 20)
            case .vk: r = try await env.spotify.searchIn(.VK, q, limit: 20)
            case .youtube: r = try await youtubeSearch(q)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.result = r
                self.submitted = q
                self.isLoading = false
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                self.error = message
                self.isLoading = false
            }
        }
    }

    /// YouTube Music: только треки (как Android-фильтр «Песни»); звук потом ищется обычным путём по названию.
    private func youtubeSearch(_ q: String) async throws -> SpotifySearchResult {
        var r = SpotifySearchResult()
        r.tracks = try await youtube.searchSongs(q).map { s in
            SpotifyTrack(id: YouTubeProvider.catalogPrefix + s.videoId, name: s.title, artists: s.artists.map { SpotifySimpleArtist(name: $0) },
                         album: s.thumbnail.map { SpotifySimpleAlbum(images: [SpotifyImage(url: $0)]) },
                         durationMs: (s.durationSec ?? 0) * 1000)
        }
        r.tracksTotal = r.tracks.count
        return r
    }

    // MARK: - История (таблица `search_history`)

    private func loadHistory() {
        guard let db = env?.database else { return }
        history = (try? db.pool.read { try String.fetchAll($0, sql: "SELECT query FROM search_history ORDER BY id DESC LIMIT 30") }) ?? []
    }

    private func saveHistory(_ q: String) {
        guard let db = env?.database, !(env?.prefs.settings.get(PK.pauseSearchHistory) ?? false) else { return }
        try? db.pool.write {
            try $0.execute(sql: "DELETE FROM search_history WHERE query = ?", arguments: [q])
            try $0.execute(sql: "INSERT INTO search_history (query) VALUES (?)", arguments: [q])
        }
        loadHistory()
    }

    func removeHistory(_ q: String) {
        guard let db = env?.database else { return }
        try? db.pool.write { try $0.execute(sql: "DELETE FROM search_history WHERE query = ?", arguments: [q]) }
        loadHistory()
    }

    func clearHistory() {
        guard let db = env?.database else { return }
        try? db.pool.write { try $0.execute(sql: "DELETE FROM search_history") }
        loadHistory()
    }
}
