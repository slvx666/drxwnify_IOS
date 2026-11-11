import SwiftUI

/// Вкладка «Библиотека»: медиатека аккаунта Spotify (LIB-010, LIB-011).
struct LibraryScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        SpotifyLibraryContent(settings: env.prefs.settings, session: env.spotifyTokens.state, library: env.library)
            .navigationTitle(L("filter_library"))
            .navigationBarItems(trailing: TopBarIcons())
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
    @State private var newName = ""

    private var userId: String { settings.get(PK.spotifySpDc).map { _ in settings.get(PK.spotifyUserId) ?? "linked" } ?? "" }
    private var isLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty }

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
        if !isLinked || filter == .songs {
            autoRow(L("liked"), "heart.fill", .red, summary.liked > 0 ? LPlural("n_song", summary.liked) : nil, LocalTrackListScreen(kind: .liked))
        }
        if filter == .all || filter == .songs {
            autoRow(L("songs"), "music.note", .blue, summary.songs > 0 ? LPlural("n_song", summary.songs) : nil, LocalTrackListScreen(kind: .songs))
            autoRow(L("downloaded_songs"), "arrow.down.circle.fill", .green, nil, LocalTrackListScreen(kind: .downloaded))
            autoRow(L("my_top"), "chart.bar.fill", .orange, nil, LocalTrackListScreen(kind: .top))
            autoRow(L("history"), "clock.arrow.circlepath", .purple, nil, HistoryScreen())
        }
        if filter == .all || filter == .playlists {
            ForEach(localPlaylists) { p in
                NavigationLink(destination: LocalPlaylistScreen(playlist: p)) {
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: p, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text(L("ios_playlist") + " · " + LPlural("n_song", p.songCount)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func autoRow<D: View>(_ title: String, _ symbol: String, _ color: Color, _ detail: String?, _ destination: D) -> some View {
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
        // «Любимые треки» всегда первыми (LIB-011), остальное — в порядке Spotify.
        return filtered.filter { $0.kind == .likedSongs } + filtered.filter { $0.kind != .likedSongs }
    }

    private var list: some View {
        List {
            chips
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
            toolsRow
                .listRowBackground(Color.clear)

            if !isLinked {
                loginRow
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
            ForEach(entries) { entry in
                NavigationLink(destination: SpotifyLibraryEntryDestination(entry: entry)) {
                    SpotifyLibraryEntryRow(entry: entry)
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

    /// Строка под фишками: порядок («Недавние»), новый плейлист, обновить.
    private var toolsRow: some View {
        HStack(spacing: 18) {
            Text(L("lib_sort_recents")).font(.subheadline.weight(.medium))
            Image(systemName: "arrow.down").font(.caption.weight(.semibold))
            Spacer()
            Button(action: { creating = true }) { Image(systemName: "plus") }
                .buttonStyle(BorderlessButtonStyle())
            Button(action: { reload(force: true) }) { Image(systemName: "arrow.clockwise") }
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
                    if entry.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundColor(.green)
                    }
                    Text(entry.kind == .likedSongs ? L("liked_songs") : entry.name).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let uri = folderUri
        loader.load(force: force) { try await api.myLibraryAll(filter: "Playlists", folderUri: uri) }
    }
}
