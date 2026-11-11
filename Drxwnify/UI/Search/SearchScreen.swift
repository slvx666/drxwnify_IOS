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
        .navigationTitle(L("search"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(env) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L("search"), text: $model.query, onCommit: { model.submit() })
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !model.query.isEmpty {
                Button(action: { model.query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.secondary.opacity(0.18))
        .clipShape(Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button(action: { filter = f }) {
                        Text(f.title)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .foregroundColor(filter == f ? Color(.systemBackground) : .primary)
                            .background(filter == f ? Color.primary : Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var history: some View {
        List {
            if !model.history.isEmpty {
                Section(header: HStack {
                    Text(L("search_history"))
                    Spacer()
                    Button(action: { confirmClear = true }) { Image(systemName: "trash") }
                }) {
                    ForEach(model.history, id: \.self) { q in
                        Button(action: {
                            model.query = q
                            model.submit()
                        }) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
                                Text(q).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { model.history[$0] }.forEach(model.removeHistory) }
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .alert(isPresented: $confirmClear) {
            Alert(title: Text(L("clear_search_history")), message: Text(L("clear_search_history_confirm")),
                  primaryButton: .destructive(Text(L("clear_search_history"))) { model.clearHistory() },
                  secondaryButton: .cancel(Text(L("cancel"))))
        }
    }

    private var results: some View {
        List {
            if let r = model.result {
                if r.isEmpty {
                    Text(L("no_results_found")).foregroundColor(.secondary).listRowBackground(Color.clear)
                }
                let short = filter == .all
                if (filter == .all || filter == .songs) && !r.tracks.isEmpty {
                    Section(header: Text(L("songs"))) {
                        let list = short ? Array(r.tracks.prefix(5)) : r.tracks
                        ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                            SpotifyTrackRow(track: t, context: list, index: i, queueTitle: model.submitted)
                        }
                    }
                }
                if (filter == .all || filter == .artists) && !r.artists.isEmpty {
                    Section(header: Text(L("artists"))) {
                        ForEach(short ? Array(r.artists.prefix(4)) : r.artists) { a in
                            NavigationLink(destination: SpotifyArtistScreen(artistId: a.id, name: a.name)) {
                                entry(a.images.best(minWidth: 150), a.name, L("ios_artist"), circle: true)
                            }
                        }
                    }
                }
                if (filter == .all || filter == .albums) && !r.albums.isEmpty {
                    Section(header: Text(L("albums"))) {
                        ForEach(short ? Array(r.albums.prefix(4)) : r.albums) { a in
                            NavigationLink(destination: SpotifyAlbumScreen(albumId: a.id, name: a.name)) {
                                entry(a.images.best(minWidth: 150), a.name,
                                      [a.artistNames, a.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            }
                        }
                    }
                }
                if (filter == .all || filter == .playlists) && !r.playlists.isEmpty {
                    Section(header: Text(L("playlists"))) {
                        ForEach(short ? Array(r.playlists.prefix(4)) : r.playlists) { p in
                            NavigationLink(destination: SpotifyPlaylistScreen(playlistId: p.id, name: p.name,
                                                                              imageUrl: p.images.best(minWidth: 300))) {
                                entry(p.images.best(minWidth: 150), p.name, p.owner?.displayName ?? L("ios_playlist"))
                            }
                        }
                    }
                }
            }
            LoadStatusRow(isLoading: model.isLoading, error: model.error, retry: { model.search(force: true) })
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
    }

    private func entry(_ image: String?, _ title: String, _ subtitle: String, circle: Bool = false) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: image, size: 48, cornerRadius: 6, circle: circle, placeholderSymbol: circle ? "person.fill" : "music.note.list")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

final class SearchModel: ObservableObject {
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
            let r = try await env.spotify.search(q)
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
