import SwiftUI

/// Вкладка «Библиотека»: медиатека аккаунта Spotify (LIB-010, LIB-011).
struct LibraryScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        SpotifyLibraryContent(settings: env.prefs.settings, session: env.spotifyTokens.state, library: env.library)
            .rootTitle(L("filter_library")) { TopBarIcons() }
    }
}

private struct SpotifyLibraryContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @ObservedObject var session: SpotifyTokenManager.State

    private enum Filter: String, CaseIterable, Identifiable {
        case all, songs, playlists, albums, artists
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L("filter_all")
            case .songs: return L("filter_songs")
            case .playlists: return L("filter_playlists")
            case .albums: return L("filter_albums")
            case .artists: return L("filter_artists")
            }
        }
    }

    @StateObject private var loader = Loader<[SpotifyLibraryEntry]>()
    @State private var filter = Filter.all
    @State private var showLogin = false
    @State private var loadedFor = ""
    @ObservedObject var library: LibraryStore
    @State private var localPlaylists: [LocalPlaylist] = []
    @State private var localArtists: [LocalArtist] = []
    @State private var summary = LibraryStore.Summary()
    @State private var creating = false
    @State private var searching = false
    @State private var importing = false
    @State private var query = ""
    @State private var newName = ""
    /// Сетка 3 в ряд или список (LIB-002), как `spotify_library_grid` на Android.
    @AppStorage("spotify_library_grid") private var grid = false
    /// Порядок: недавние (как в аккаунте), дата добавления, по алфавиту, автор.
    @AppStorage("library_sort") private var sortRaw = "RECENTS"
    @ObservedObject private var pins = LibraryPins.shared

    private enum Sort: String, CaseIterable {
        case recents = "RECENTS", dateAdded = "DATE_ADDED", name = "NAME", creator = "CREATOR"
        var title: String {
            switch self {
            case .recents: return L("lib_sort_recents")
            case .dateAdded: return L("lib_sort_recently_added")
            case .name: return L("lib_sort_alphabetical")
            case .creator: return L("lib_sort_creator")
            }
        }
    }

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .recents }

    /// Чья медиатека на экране: аккаунт Spotify или Яндекса (основной источник, как `Catalog.source`).
    private var userId: String {
        if env.spotify.yandexIsSource { return "ym:" + (settings.get(PK.yandexUid) ?? "linked") }
        return settings.get(PK.spotifySpDc).map { _ in settings.get(PK.spotifyUserId) ?? "linked" } ?? ""
    }
    private var isLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty || env.spotify.yandexIsSource }

    var body: some View {
        list
        .sheet(isPresented: $showLogin) {
            SpotifyLoginScreen().environmentObject(env)
        }
        .onAppear {
            reloadIfNeeded()
            reloadLocal()
        }
        .onChange(of: userId) { _ in reloadIfNeeded() }
        .onChange(of: library.revision) { _ in reloadLocal() }
    }

    /// Без входа в Spotify библиотека показывает своё, а вход предлагается строкой сверху.
    private var loginRow: some View {
        Button(action: { showLogin = true }) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.house").font(.title2).foregroundColor(.green).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(session.needsReLogin ? "spotify_relogin" : "spotify_login")).foregroundColor(.primary)
                    Text(L(session.needsReLogin ? "spotify_login_error_expired" : "spotify_login_description"))
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
    }

    /// Своё: автоплейлисты (LIB-019) и свои плейлисты (LIB-016).
    @ViewBuilder private var localSection: some View {
        if creating {
            HStack {
                TextField(L("playlist_name"), text: $newName, onCommit: createPlaylist)
                Button(L("create_playlist"), action: createPlaylist).buttonStyle(BorderlessButtonStyle())
                Button(action: cancelCreate) { Image(systemName: "xmark") }.buttonStyle(BorderlessButtonStyle())
            }
        }
        if (!isLinked || filter == .songs) && (settings.get(PK.showLikedPlaylist) ?? true) {
            autoRow(L("liked"), "heart.fill", .red, summary.liked > 0 ? LPlural("n_song", summary.liked) : nil, LocalTrackListScreen(kind: .liked))
        }
        // Как на Android: «Композиции», «Скачанные», «Мой топ» — под фишкой «Локальные» (или без аккаунта).
        if filter == .songs || !isLinked {
            autoRow(L("songs"), "music.note", .blue, summary.songs > 0 ? LPlural("n_song", summary.songs) : nil, LocalTrackListScreen(kind: .songs))
            if settings.get(PK.showDownloadedPlaylist) ?? true {
                autoRow(L("downloaded_songs"), "arrow.down.circle.fill", .green, nil, LocalTrackListScreen(kind: .downloaded))
            }
            if settings.get(PK.showTopPlaylist) ?? true {
                autoRow(L("my_top"), "chart.bar.fill", .orange, nil, LocalTrackListScreen(kind: .top))
            }
        }
    }

    private func localPlaylistRow(_ p: LocalPlaylist) -> some View {
        NavigationLink(destination: LocalPlaylistScreen(playlist: p)) {
            HStack(spacing: 12) {
                PlaylistCover(playlist: p, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if pins.pinned.contains(LibraryPins.localKey(p.id)) {
                            Image(systemName: "pin.fill").font(.caption2).foregroundColor(.green)
                        }
                        Text(p.name).lineLimit(1)
                    }
                    Text(L("ios_playlist") + " · " + LPlural("n_song", p.songCount)).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            Button(action: { pins.toggle(LibraryPins.localKey(p.id)) }) {
                Label(L(pins.pinned.contains(LibraryPins.localKey(p.id)) ? "library_unpinned" : "library_pinned"), systemImage: "pin")
            }
        }
        .themedRow()
    }

    /// Строка общего списка: запись медиатеки или свой плейлист.
    private enum LibRow: Identifiable {
        case entry(SpotifyLibraryEntry)
        case local(LocalPlaylist)
        var id: String {
            switch self {
            case .entry(let e): return "e:" + e.id
            case .local(let p): return "l:" + p.id
            }
        }
    }

    /// Как на Android: «Любимые треки», затем закреплённое (медиатека и свои плейлисты) в порядке закрепления,
    /// затем свои плейлисты, затем остальная медиатека в выбранном порядке.
    private var rows: [LibRow] {
        var out: [(Int, Int, LibRow)] = []
        for (i, e) in entries.enumerated() {
            let r = e.kind == .likedSongs ? -1 : (pins.index(LibraryPins.key(e)) ?? 200_000)
            out.append((r, i, .entry(e)))
        }
        if filter == .all || filter == .playlists {
            let q = query.trimmingCharacters(in: .whitespaces)
            for (i, p) in localPlaylists.enumerated() where q.isEmpty || p.name.localizedCaseInsensitiveContains(q) {
                out.append((pins.index(LibraryPins.localKey(p.id)) ?? 100_000, i, .local(p)))
            }
        }
        return out.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
    }

    private func autoRow<D: View>(_ title: String, _ symbol: String, _ color: Color, _ detail: String?, _ destination: D) -> some View {
        autoRowLink(title, symbol, color, detail, destination).themedRow()
    }

    private func autoRowLink<D: View>(_ title: String, _ symbol: String, _ color: Color, _ detail: String?, _ destination: D) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let d = detail { Text(d).font(.caption).foregroundColor(.secondary) }
                }
            }
        }
    }

    private func cancelCreate() {
        creating = false
        newName = ""
    }

    private func createPlaylist() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        library.createPlaylist(name: name)
        cancelCreate()
    }

    private func reloadLocal() {
        let lib = library
        DispatchQueue.global(qos: .userInitiated).async {
            let p = lib.playlists(), s = lib.summary(), a = lib.artists()
            DispatchQueue.main.async {
                localPlaylists = p
                summary = s
                localArtists = a
            }
        }
    }

    private var entries: [SpotifyLibraryEntry] {
        let all = loader.value ?? []
        let filtered: [SpotifyLibraryEntry]
        switch filter {
        case .all: filtered = all
        case .songs: filtered = []
        case .playlists: filtered = all.filter { $0.kind == .playlist || $0.kind == .folder || $0.kind == .likedSongs }
        case .albums: filtered = all.filter { $0.kind == .album }
        case .artists: filtered = all.filter { $0.kind == .artist }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let matched = q.isEmpty ? filtered : filtered.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.creator ?? "").localizedCaseInsensitiveContains(q)
        }
        let sorted: [SpotifyLibraryEntry]
        switch sort {
        case .recents: sorted = matched
        case .dateAdded:
            sorted = matched.enumerated().sorted { a, b in
                let x = a.element.addedAt ?? "", y = b.element.addedAt ?? ""
                return x != y ? x > y : a.offset < b.offset
            }.map { $0.element }
        case .name: sorted = matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .creator:
            sorted = matched.sorted { a, b in
                let c = (a.creator ?? a.name).localizedCaseInsensitiveCompare(b.creator ?? b.name)
                return c != .orderedSame ? c == .orderedAscending : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        // «Любимые треки» всегда первыми (LIB-011), затем закрепления в порядке закрепления.
        func rank(_ e: SpotifyLibraryEntry) -> Int { e.kind == .likedSongs ? -1 : (pins.index(LibraryPins.key(e)) ?? Int.max) }
        return sorted.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
    }

    private var list: some View {
        List {
            chips
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
            toolsRow
                .background(NavigationLink(destination: ImportPlaylistScreen(), isActive: $importing) { EmptyView() }.opacity(0))
                .listRowBackground(Color.clear)
            if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(L("search"), text: $query)
                    if !query.isEmpty { Button(action: { query = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(BorderlessButtonStyle()) }
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
                .listRowBackground(Color.clear)
            }

            if !isLinked {
                loginRow
                NavigationLink(destination: IntegrationsScreen(settings: settings)) {
                    HStack(spacing: 12) {
                        Image(systemName: "y.circle.fill").font(.title2).foregroundColor(.yellow).frame(width: 48, height: 48)
                        Text(L("yandex_login")).foregroundColor(.primary)
                    }
                }
            }
            if filter == .all || filter == .songs || filter == .playlists {
                localSection
            }
            if (filter == .artists || filter == .all) && !isLinked {
                ForEach(localArtists) { a in
                    NavigationLink(destination: LocalArtistScreen(artist: a)) {
                        HStack(spacing: 12) {
                            ArtworkView(url: a.thumbnailUrl, size: 48, circle: true, placeholderSymbol: "person.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).lineLimit(1)
                                Text(LPlural("n_song", a.songCount)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            if grid && (filter == .all || filter == .playlists) {
                ForEach(localPlaylists) { localPlaylistRow($0) }
            }
            if grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                    ForEach(entries) { entry in
                        NavigationLink(destination: SpotifyLibraryEntryDestination(entry: entry)) {
                            SpotifyLibraryEntryCell(entry: entry, pinnedHere: pins.pinned.contains(LibraryPins.key(entry)))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu { pinButton(entry) }
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in
                    switch row {
                    case .entry(let entry):
                        NavigationLink(destination: SpotifyLibraryEntryDestination(entry: entry)) {
                            SpotifyLibraryEntryRow(entry: entry, pinnedHere: pins.pinned.contains(LibraryPins.key(entry)))
                        }
                        .contextMenu { pinButton(entry) }
                        .themedRow()
                    case .local(let p):
                        localPlaylistRow(p)
                    }
                }
            }

            if case .failed(let message) = loader.state {
                LoadStatusRow(isLoading: false, error: message, retry: { reload(force: true) })
            } else if loader.isLoading {
                LoadStatusRow(isLoading: true, error: nil, retry: {})
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
    }

    /// Фишки-фильтры, как на Android: повторное нажатие снимает фильтр.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([Filter.playlists, .albums, .artists, .songs]) { f in
                    Button(action: { filter = filter == f ? .all : f }) {
                        Text(f == .songs ? L("ios_filter_local") : f.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).frame(height: 36)
                            .foregroundColor(filter == f ? Color(.systemBackground) : .primary)
                            .background(Capsule().fill(filter == f ? Color.accentColor : Color.secondary.opacity(0.22)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func pinButton(_ entry: SpotifyLibraryEntry) -> some View {
        if entry.kind != .likedSongs {
            Button(action: {
                pins.toggle(LibraryPins.key(entry))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                if pins.pinned.contains(LibraryPins.key(entry)) {
                    Label(L("library_unpinned"), systemImage: "pin.slash")
                } else {
                    Label(L("library_pinned"), systemImage: "pin")
                }
            }
        }
    }

    /// Строка под фишками: порядок, вид (список/сетка), новый плейлист, обновить.
    private var toolsRow: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(Sort.allCases, id: \.self) { s in
                    Button(action: { sortRaw = s.rawValue }) {
                        if s == sort { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
                Divider()
                Button(action: { creating = true }) { Label(L("create_playlist"), systemImage: "plus") }
                Button(action: { importing = true }) { Label(L("import_playlist"), systemImage: "square.and.arrow.down.on.square") }
                Button(action: { reload(force: true) }) { Label(L("refetch"), systemImage: "arrow.clockwise") }
            } label: {
                HStack(spacing: 4) {
                    Text(sort.title).font(.subheadline.weight(.medium))
                    Text("·").foregroundColor(.secondary)
                    Image(systemName: "arrow.down").font(.caption.weight(.semibold))
                }
            }
            Spacer()
            Button(action: { withAnimation { searching.toggle(); if !searching { query = "" } } }) { Image(systemName: "magnifyingglass") }
                .buttonStyle(BorderlessButtonStyle())
            Button(action: { grid.toggle() }) { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                .buttonStyle(BorderlessButtonStyle())
        }
        .foregroundColor(.primary)
    }

    private func reloadIfNeeded() {
        guard isLinked else {
            loader.reset()
            loadedFor = ""
            return
        }
        if loadedFor != userId {
            loadedFor = userId
            reload(force: true)
        } else {
            reload(force: false)
        }
    }

    private func reload(force: Bool) {
        let api = env.spotify
        loader.load(force: force) { try await api.myLibraryAll() }
    }
}

struct SpotifyLibraryEntryRow: View {
    let entry: SpotifyLibraryEntry
    /// Закреплено на этом телефоне.
    var pinnedHere = false

    private var subtitle: String {
        switch entry.kind {
        case .likedSongs: return entry.totalCount > 0 ? LPlural("n_song", entry.totalCount) : L("filter_playlists")
        case .playlist: return [L("ios_playlist"), entry.creator].compactMap { $0 }.joined(separator: " · ")
        case .album: return [L("ios_album"), entry.creator].compactMap { $0 }.joined(separator: " · ")
        case .artist: return L("ios_artist")
        case .folder: return L("ios_folder")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if entry.kind == .likedSongs {
                ZStack {
                    LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "heart.fill").foregroundColor(.white)
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                ArtworkView(url: entry.imageUrl, size: 52, circle: entry.kind == .artist,
                            placeholderSymbol: entry.kind == .artist ? "person.fill" : (entry.kind == .folder ? "folder.fill" : "music.note.list"))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.pinned || pinnedHere {
                        Image(systemName: "pin.fill").font(.caption2).foregroundColor(pinnedHere ? .accentColor : .green)
                    }
                    Text(entry.kind == .likedSongs ? L("liked_songs") : entry.name).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Ячейка сетки библиотеки: обложка и название.
struct SpotifyLibraryEntryCell: View {
    let entry: SpotifyLibraryEntry
    var pinnedHere = false

    private var side: CGFloat { ((UIMetrics.width - 32 - 20) / 3).rounded(.down) }

    var body: some View {
        VStack(alignment: entry.kind == .artist ? .center : .leading, spacing: 4) {
            cover
                .overlay(pin, alignment: .topTrailing)
            Text(entry.kind == .likedSongs ? L("liked_songs") : entry.name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .frame(width: side)
    }

    @ViewBuilder private var cover: some View {
        if entry.kind == .likedSongs {
            ZStack {
                LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "heart.fill").font(.title).foregroundColor(.white)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ArtworkView(url: entry.imageUrl, size: side, cornerRadius: 8, circle: entry.kind == .artist,
                        placeholderSymbol: entry.kind == .artist ? "person.fill" : (entry.kind == .folder ? "folder.fill" : "music.note.list"))
        }
    }

    @ViewBuilder private var pin: some View {
        if entry.pinned || pinnedHere {
            Image(systemName: "pin.fill").font(.caption2).foregroundColor(.white)
                .padding(5).background(Circle().fill(Color.black.opacity(0.55))).padding(4)
        }
    }
}

struct SpotifyLibraryEntryDestination: View {
    let entry: SpotifyLibraryEntry

    var body: some View {
        switch entry.kind {
        case .likedSongs: SpotifyLikedSongsScreen()
        case .playlist: SpotifyPlaylistScreen(playlistId: entry.id, name: entry.name, imageUrl: entry.imageUrl)
        case .album: SpotifyAlbumScreen(albumId: entry.id, name: entry.name)
        case .artist: SpotifyArtistScreen(artistId: entry.id, name: entry.name)
        case .folder: SpotifyFolderScreen(folderUri: entry.uri, name: entry.name)
        }
    }
}

/// Папка плейлистов Spotify (UI-043).
struct SpotifyFolderScreen: View {
    let folderUri: String
    let name: String

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var loader = Loader<[SpotifyLibraryEntry]>()

    var body: some View {
        List {
            ForEach(loader.value ?? []) { entry in
                NavigationLink(destination: SpotifyLibraryEntryDestination(entry: entry)) {
                    SpotifyLibraryEntryRow(entry: entry)
                }
            }
            if case .failed(let message) = loader.state {
                LoadStatusRow(isLoading: false, error: message, retry: { load(force: true) })
            } else if loader.isLoading {
                LoadStatusRow(isLoading: true, error: nil, retry: {})
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let uri = folderUri
        loader.load(force: force) { try await api.myLibraryAll(filter: "Playlists", folderUri: uri) }
    }
}
