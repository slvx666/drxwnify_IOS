import SwiftUI

/// Плейлист Spotify (UI-039).
struct SpotifyPlaylistScreen: View {
    let playlistId: String
    let name: String
    var imageUrl: String?

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var info = Loader<SpotifyPlaylist>()
    @StateObject private var tracks = PagedLoader<SpotifyPlaylistTrack>()

    var body: some View {
        List {
            SpotifyHeader(
                imageUrl: info.value?.images.best(minWidth: 300) ?? imageUrl,
                title: info.value?.name ?? name,
                subtitle: info.value?.owner?.displayName,
                detail: tracks.total > 0 ? LPlural("n_song", tracks.total) : nil
            )
            ForEach(Array(tracks.items.enumerated()), id: \.offset) { _, item in
                SpotifyTrackRow(track: item.track)
            }
            LoadStatusRow(isLoading: tracks.isLoading, error: tracks.error, retry: { load(force: true) })
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(info.value?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let id = playlistId
        info.load(force: force) { try await api.playlist(id) }
        tracks.load(force: force, pageSize: 100) { offset, limit in
            let page = try await api.playlistTracks(id, limit: limit, offset: offset)
            return (page.items, page.total)
        }
    }
}

/// «Любимые треки» аккаунта (UI-042).
struct SpotifyLikedSongsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var tracks = PagedLoader<SpotifyPlaylistTrack>()

    var body: some View {
        List {
            if tracks.total > 0 {
                Text(LPlural("n_song", tracks.total))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(tracks.items.enumerated()), id: \.offset) { _, item in
                SpotifyTrackRow(track: item.track)
            }
            LoadStatusRow(isLoading: tracks.isLoading, error: tracks.error, retry: { load(force: true) })
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(L("liked_songs"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        tracks.load(force: force, pageSize: 50) { offset, limit in
            let page = try await api.likedSongs(limit: limit, offset: offset)
            return (page.items, page.total)
        }
    }
}

/// Альбом каталога (UI-040).
struct SpotifyAlbumScreen: View {
    let albumId: String
    let name: String

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var loader = Loader<SpotifyAlbum>()

    var body: some View {
        List {
            if let album = loader.value {
                SpotifyHeader(
                    imageUrl: album.images.best(minWidth: 300),
                    title: album.name,
                    subtitle: album.artistNames,
                    detail: [album.year, album.totalTracks > 0 ? LPlural("n_song", album.totalTracks) : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                ForEach(album.artists.filter { $0.id != nil }, id: \.self) { artist in
                    NavigationLink(destination: SpotifyArtistScreen(artistId: artist.id ?? "", name: artist.name)) {
                        Label(artist.name, systemImage: "person.fill")
                    }
                }
                ForEach(Array(album.tracks.enumerated()), id: \.offset) { index, track in
                    SpotifyTrackRow(track: track, number: index + 1)
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
        .navigationTitle(loader.value?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let id = albumId
        loader.load(force: force) { try await api.album(id) }
    }
}

/// Артист каталога (UI-041): популярные треки, альбомы, синглы, похожие.
struct SpotifyArtistScreen: View {
    let artistId: String
    let name: String

    struct Page {
        var artist: SpotifyArtist
        var top: [SpotifyTrack]
        var discography: SpotifyArtistDiscography
        var related: [SpotifyArtist]
    }

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var loader = Loader<Page>()

    var body: some View {
        List {
            if let page = loader.value {
                SpotifyHeader(
                    imageUrl: page.artist.images.best(minWidth: 300),
                    title: page.artist.name,
                    detail: page.artist.monthlyListeners.map {
                        L("spotify_monthly_listeners", NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))
                    },
                    circle: true
                )
                if !page.top.isEmpty {
                    Section(header: Text(L("artist_top_tracks"))) {
                        ForEach(page.top.prefix(10)) { SpotifyTrackRow(track: $0) }
                    }
                }
                albumShelf(L("albums"), page.discography.albums)
                albumShelf(L("singles_and_eps"), page.discography.singles)
                albumShelf(L("ios_compilations"), page.discography.compilations)
                if !page.related.isEmpty {
                    Section(header: Text(L("similar_artists"))) {
                        SpotifyShelf(items: page.related,
                                     imageUrl: { $0.images.best(minWidth: 250) },
                                     title: { $0.name },
                                     subtitle: { _ in nil },
                                     circle: true) { SpotifyArtistScreen(artistId: $0.id, name: $0.name) }
                    }
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
        .navigationTitle(loader.value?.artist.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [SpotifyAlbum]) -> some View {
        if !albums.isEmpty {
            Section(header: Text(title)) {
                SpotifyShelf(items: albums,
                             imageUrl: { $0.images.best(minWidth: 250) },
                             title: { $0.name },
                             subtitle: { $0.year }) { SpotifyAlbumScreen(albumId: $0.id, name: $0.name) }
            }
        }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let id = artistId
        loader.load(force: force) {
            // Все четыре запроса читают один и тот же закэшированный ответ queryArtistOverview.
            let artist = try await api.artist(id)
            return Page(artist: artist,
                        top: (try? await api.artistTopTracks(id)) ?? [],
                        discography: (try? await api.artistDiscography(id)) ?? SpotifyArtistDiscography(),
                        related: (try? await api.artistRelatedArtists(id)) ?? [])
        }
    }
}
