import SwiftUI

/// Вкладка «Библиотека»: медиатека аккаунта Spotify (LIB-010, LIB-011).
struct LibraryScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        SpotifyLibraryContent(settings: env.prefs.settings, session: env.spotifyTokens.state)
            .navigationTitle(L("filter_library"))
    }
}

private struct SpotifyLibraryContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @ObservedObject var session: SpotifyTokenManager.State

    private enum Filter: String, CaseIterable, Identifiable {
        case all, playlists, albums, artists
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L("filter_all")
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

    private var userId: String { settings.get(PK.spotifySpDc).map { _ in settings.get(PK.spotifyUserId) ?? "linked" } ?? "" }
    private var isLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty }

    var body: some View {
        Group {
            if isLinked {
                list
            } else {
                loginPrompt
            }
        }
        .sheet(isPresented: $showLogin) {
            SpotifyLoginScreen().environmentObject(env)
        }
        .onAppear(perform: reloadIfNeeded)
        .onChange(of: userId) { _ in reloadIfNeeded() }
    }

    private var loginPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundColor(.secondary)
            Text(L(session.needsReLogin ? "spotify_login_error_expired" : "spotify_login_description"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(L(session.needsReLogin ? "spotify_relogin" : "spotify_login")) { showLogin = true }
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.green))
                .foregroundColor(.black)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .miniPlayerInset()
    }

    private var entries: [SpotifyLibraryEntry] {
        let all = loader.value ?? []
        let filtered: [SpotifyLibraryEntry]
        switch filter {
        case .all: filtered = all
        case .playlists: filtered = all.filter { $0.kind == .playlist || $0.kind == .folder || $0.kind == .likedSongs }
        case .albums: filtered = all.filter { $0.kind == .album }
        case .artists: filtered = all.filter { $0.kind == .artist }
        }
        // «Любимые треки» всегда первыми (LIB-011), остальное — в порядке Spotify.
        return filtered.filter { $0.kind == .likedSongs } + filtered.filter { $0.kind != .likedSongs }
    }

    private var list: some View {
        List {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(SegmentedPickerStyle())
            .listRowBackground(Color.clear)

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
        .navigationBarItems(trailing: Button(action: { reload(force: true) }) {
            Image(systemName: "arrow.clockwise")
        })
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
