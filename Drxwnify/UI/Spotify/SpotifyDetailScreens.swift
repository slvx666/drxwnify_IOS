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
            PlayShuffleRow(tracks: tracks.items.map { $0.track }, queueTitle: info.value?.name ?? name)
            ForEach(Array(tracks.items.enumerated()), id: \.offset) { i, item in
                SpotifyTrackRow(track: item.track, context: tracks.items.map { $0.track }, index: i, queueTitle: info.value?.name ?? name)
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
            PlayShuffleRow(tracks: tracks.items.map { $0.track }, queueTitle: L("liked_songs"))
            ForEach(Array(tracks.items.enumerated()), id: \.offset) { i, item in
                SpotifyTrackRow(track: item.track, context: tracks.items.map { $0.track }, index: i, queueTitle: L("liked_songs"))
            }
            LoadStatusRow(isLoading: tracks.isLoading, error: tracks.error, retry: { load(force: true) })
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(L("liked_songs"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
        .onChange(of: tracks.items.count) { _ in env.likes.markLiked(tracks.items.map { $0.track.id }) }
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
                    detail: [album.typeTitle, album.fullDate, album.totalTracks > 0 ? LPlural("n_song", album.totalTracks) : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                GenreChips(artist: album.artists.first?.name ?? "", album: album.name)
                ForEach(album.artists.filter { $0.id != nil }, id: \.self) { artist in
                    NavigationLink(destination: SpotifyArtistScreen(artistId: artist.id ?? "", name: artist.name)) {
                        Label(artist.name, systemImage: "person.fill")
                    }
                }
                PlayShuffleRow(tracks: album.tracks, queueTitle: album.name, album: album.simple)
                ForEach(Array(album.tracks.enumerated()), id: \.offset) { index, track in
                    SpotifyTrackRow(track: track, number: index + 1, context: album.tracks, index: index,
                                    queueTitle: album.name, album: album.simple, showPlayCount: true, origin: .album)
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
        .navigationBarItems(trailing: HStack(spacing: 14) {
            RemoteToggleButton(onSymbol: "checkmark.circle.fill", offSymbol: "plus.circle",
                               onLabel: L("remove_from_library"), offLabel: L("add_to_library"),
                               read: { [api = env.spotify, id = albumId] in try await api.isAlbumSaved(id) },
                               write: { [api = env.spotify, id = albumId] on in try await api.setAlbumSaved(id, saved: on) })
            ShareLinkButton(text: AppLinks.shareText(.album, id: albumId, title: loader.value?.name ?? name, by: loader.value?.artistNames))
        })
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
        var appearsOn: [SpotifyAlbum] = []
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
                GenreChips(artist: page.artist.name)
                if !page.top.isEmpty {
                    PlayShuffleRow(tracks: page.top, queueTitle: page.artist.name, artistId: page.artist.id)
                    Section(header: Text(L("artist_top_tracks"))) {
                        ForEach(Array(page.top.prefix(10).enumerated()), id: \.offset) { i, t in
                            SpotifyTrackRow(track: t, context: Array(page.top.prefix(10)), index: i, queueTitle: page.artist.name,
                                            origin: .artist(page.artist.id, shuffleAll: false))
                        }
                    }
                }
                albumShelf(L("albums"), page.discography.albums)
                albumShelf(L("singles_and_eps"), page.discography.singles)
                albumShelf(L("ios_compilations"), page.discography.compilations)
                if !page.appearsOn.isEmpty {
                    Section(header: Text(L("artist_appears_on"))) {
                        SpotifyShelf(items: page.appearsOn,
                                     imageUrl: { $0.images.best(minWidth: 250) },
                                     title: { $0.name },
                                     subtitle: { $0.artistNames }) { SpotifyAlbumScreen(albumId: $0.id, name: $0.name) }
                    }
                }
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
        .navigationBarItems(trailing: HStack(spacing: 14) {
            RemoteToggleButton(onSymbol: "person.crop.circle.badge.checkmark", offSymbol: "person.crop.circle.badge.plus",
                               onLabel: L("subscribed"), offLabel: L("subscribe"),
                               read: { [api = env.spotify, id = artistId] in try await api.isFollowingArtist(id) },
                               write: { [api = env.spotify, id = artistId] on in try await api.setFollowingArtist(id, follow: on) })
            ShareLinkButton(text: AppLinks.shareText(.artist, id: artistId, title: loader.value?.artist.name ?? name, by: nil))
        })
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
                        related: (try? await api.artistRelatedArtists(id)) ?? [],
                        appearsOn: (try? await api.artistAppearsOn(id)) ?? [])
        }
    }
}
