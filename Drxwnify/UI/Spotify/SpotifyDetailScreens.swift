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
        .hidesTabChrome()
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
        .hidesTabChrome()
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
                let tracks = album.tracks.map { Track($0, album: album.simple) }
                VStack(spacing: 6) {
                    ArtworkView(url: album.images.best(minWidth: 300), size: min(230, UIMetrics.width * 0.62), cornerRadius: 10)
                        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 6)
                        .padding(.bottom, 6)
                    Text(album.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    AlbumArtistsLine(artists: album.artists)
                    Text([album.typeTitle, album.fullDate, album.totalTracks > 0 ? LPlural("n_song", album.totalTracks) : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .listRowBackground(Color.clear)
                .listRowSeparatorHiddenCompat()
                GenreChips(artist: album.artists.first?.name ?? "", album: album.name, centered: true)
                    .listRowSeparatorHiddenCompat()
                AlbumButtonsRow(tracks: tracks, albumId: album.id,
                                play: { env.player.play(tracks, title: album.name, shuffled: false, origin: .album) })
                    .listRowSeparatorHiddenCompat()
                ForEach(Array(album.tracks.enumerated()), id: \.offset) { index, track in
                    SpotifyTrackRow(track: track, context: album.tracks, index: index,
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
        .environment(\.defaultMinListRowHeight, 0)
        // Как просил пользователь: на iPhone название над обложкой не дублируется.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .navigationBarItems(trailing: HStack(spacing: 16) {
            Button(action: {
                if let a = loader.value { env.trackSelection = TrackBatch(tracks: a.tracks.map { Track($0, album: a.simple) }) }
            }) { Image(systemName: "checklist") }
            .disabled(loader.value == nil)
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
    @EnvironmentObject private var player: PlayerController
    @StateObject private var loader = Loader<Page>()
    @State private var following: Bool?
    @State private var showAllTop = false
    @State private var radioBusy = false
    @State private var shuffleBusy = false
    @State private var bioExpanded = false

    private var settings: TypedStore { env.prefs.settings }

    var body: some View {
        List {
            if let page = loader.value {
                ArtistHero(imageUrl: page.artist.images.best(minWidth: 600), title: page.artist.name)
                GenreChips(artist: page.artist.name)
                actions(page)
                stats(page)
                if !page.top.isEmpty {
                    sectionTitle(L("artist_top_tracks"))
                    let shown = Array(page.top.prefix(showAllTop ? 10 : 5))
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                        SpotifyTrackRow(track: t, context: Array(page.top.prefix(10)), index: i, queueTitle: page.artist.name,
                                        origin: .artist(page.artist.id, shuffleAll: false))
                    }
                    if page.top.count > 5 {
                        Button(showAllTop ? L("ios_show_less") : L("ios_show_all")) { withAnimation { showAllTop.toggle() } }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .listRowBackground(Color.clear)
                    }
                }
                albumShelf(L("albums"), page.discography.albums)
                albumShelf(L("singles_and_eps"), page.discography.singles)
                albumShelf(L("ios_compilations"), page.discography.compilations)
                if !page.appearsOn.isEmpty {
                    sectionTitle(L("artist_appears_on"))
                    SpotifyShelf(items: page.appearsOn,
                                 imageUrl: { $0.images.best(minWidth: 250) },
                                 title: { $0.name },
                                 subtitle: { $0.artistNames }) { SpotifyAlbumScreen(albumId: $0.id, name: $0.name) }
                }
                if !page.related.isEmpty {
                    sectionTitle(L("similar_artists"))
                    SpotifyShelf(items: page.related,
                                 imageUrl: { $0.images.best(minWidth: 250) },
                                 title: { $0.name },
                                 subtitle: { _ in nil },
                                 circle: true) { SpotifyArtistScreen(artistId: $0.id, name: $0.name) }
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
        .environment(\.defaultMinListRowHeight, 0)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .navigationBarItems(trailing:
            ShareLinkButton(text: AppLinks.shareText(.artist, id: artistId, title: loader.value?.artist.name ?? name, by: nil)))
        .onAppear {
            load(force: false)
            readFollowing()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).foregroundColor(.accentColor)
            .padding(.top, 14)
            .listRowBackground(Color.clear)
            .listRowSeparatorHiddenCompat()
    }

    /// «Вы подписаны / Подписаться», «Радио», круглые «Перемешать» и «Играть» — как на Android.
    private func actions(_ page: Page) -> some View {
        let tracks = page.top.map { Track($0) }
        return HStack(spacing: 10) {
            Button(action: toggleFollow) {
                Text(L(following == true ? "subscribed" : "subscribe"))
                    .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(following == nil)
            Button(action: { startRadio(tracks, page.artist.name) }) {
                HStack(spacing: 6) {
                    if radioBusy { ProgressView() } else { Image(systemName: "dot.radiowaves.left.and.right") }
                    Text(L("radio")).lineLimit(1)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(tracks.isEmpty || radioBusy)
            // «Перемешать» — вся дискография без повторов, после неё — похожие (Android 2.2.5).
            Button(action: { shuffleAll(page, tracks) }) {
                Group {
                    if shuffleBusy { ProgressView() } else { Image(systemName: "shuffle").font(.system(size: 18, weight: .semibold)) }
                }
                .foregroundColor(Color(.systemBackground))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(tracks.isEmpty || shuffleBusy)
        }
        .foregroundColor(.primary)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }

    private func circleButton(_ symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundColor(filled ? Color(.systemBackground) : .primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(filled ? Color.accentColor : Color.accentColor.opacity(0.25)))
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// «О исполнителе»: подписчики, слушатели за месяц, описание с «Показать больше» — как на Android.
    @ViewBuilder private func stats(_ page: Page) -> some View {
        let followers = (settings.get(PK.showArtistSubscriberCount) ?? true) ? page.artist.followers : nil
        let monthly = (settings.get(PK.showMonthlyListeners) ?? true) ? page.artist.monthlyListeners : nil
        let bio = (settings.get(PK.showArtistDescription) ?? true) ? page.artist.biography : nil
        if followers != nil || monthly != nil || bio != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("about_artist")).font(.headline)
                if let f = followers { Text(L("ios_artist_followers", Self.compact(f))).font(.subheadline).foregroundColor(.secondary) }
                if let m = monthly {
                    Text(L("spotify_monthly_listeners", NumberFormatter.localizedString(from: NSNumber(value: m), number: .decimal)))
                        .font(.subheadline).foregroundColor(.secondary)
                }
                if let b = bio {
                    Text(b).font(.subheadline).foregroundColor(.secondary)
                        .lineLimit(bioExpanded ? nil : 3)
                        .padding(.top, 4)
                    Button(L(bioExpanded ? "show_less" : "show_more")) { withAnimation { bioExpanded.toggle() } }
                        .font(.caption.weight(.semibold)).foregroundColor(.accentColor)
                        .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.top, 8)
            .listRowBackground(Color.clear)
            .listRowSeparatorHiddenCompat()
        }
    }

    private func shuffleAll(_ page: Page, _ top: [Track]) {
        shuffleBusy = true
        let api = env.spotify, id = page.artist.id, name = page.artist.name
        Task {
            let all = await ArtistRadio.discography(artistId: id, top: top, api: api)
            await MainActor.run {
                shuffleBusy = false
                player.play(all.isEmpty ? top : all, title: name, shuffled: true, origin: .artistDiscography(id))
            }
        }
    }

    /// 417 000 → «417 тыс.», 1 200 000 → «1,2 млн».
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f", Double(n) / 1_000_000).replacingOccurrences(of: ".0", with: "") + " " + L("ios_millions_short") }
        if n >= 10_000 { return "\(n / 1000) " + L("ios_thousands_short") }
        return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [SpotifyAlbum]) -> some View {
        if !albums.isEmpty {
            sectionTitle(title)
            SpotifyShelf(items: albums,
                         imageUrl: { $0.images.best(minWidth: 250) },
                         title: { $0.name },
                         subtitle: { $0.year }) { SpotifyAlbumScreen(albumId: $0.id, name: $0.name) }
        }
    }

    /// Подписка — как на Android: на этом телефоне (подписки из копии) или в медиатеке аккаунта.
    private func readFollowing() {
        guard following == nil else { return }
        let api = env.spotify, id = artistId, lib = env.library
        if lib.isArtistBookmarked(spotifyId: id) { following = true; return }
        Task {
            let on = (try? await api.isFollowingArtist(id)) ?? false
            await MainActor.run { following = on }
        }
    }

    private func toggleFollow() {
        guard let on = following else { return }
        following = !on
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let api = env.spotify, id = artistId
        let page = loader.value
        env.library.setArtistBookmarked(spotifyId: id, name: page?.artist.name ?? name,
                                        thumbnail: page?.artist.images.best(minWidth: 300), !on)
        Task { try? await api.setFollowingArtist(id, follow: !on) }
    }

    /// «Радио»: топ артиста, затем похожие исполнители (как радио артиста на Android).
    private func startRadio(_ tracks: [Track], _ title: String) {
        guard let seed = tracks.first else { return }
        radioBusy = true
        let api = env.spotify
        Task {
            let similar = await SimilarArtistsRadio.build(seed: seed, api: api)
            var list = Array(tracks.prefix(3))
            let have = Set(list.map { $0.id })
            list += similar.filter { !have.contains($0.id) }
            await MainActor.run {
                radioBusy = false
                player.play(list.shuffled(), title: title + " · " + L("radio"), origin: .radio(ListRadio(original: list, api: api)))
            }
        }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let id = artistId
        loader.load(force: force) {
            // Все запросы читают один и тот же закэшированный ответ queryArtistOverview.
            let artist = try await api.artist(id)
            return Page(artist: artist,
                        top: (try? await api.artistTopTracks(id)) ?? [],
                        discography: (try? await api.artistDiscography(id)) ?? SpotifyArtistDiscography(),
                        related: (try? await api.artistRelatedArtists(id)) ?? [],
                        appearsOn: (try? await api.artistAppearsOn(id)) ?? [])
        }
    }
}

/// Шапка артиста во всю ширину: фото, затемнение книзу и имя поверх (как на Android).
struct ArtistHero: View {
    let imageUrl: String?
    let title: String

    var body: some View {
        let w = UIMetrics.width
        let h = min(w * 0.9, UIMetrics.isShort ? 260 : 360)
        return ZStack(alignment: .bottomLeading) {
            ArtworkView(url: imageUrl, size: w, cornerRadius: 0, placeholderSymbol: "person.fill")
                .frame(width: w, height: h)
                .clipped()
            LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom)
                .frame(width: w, height: h)
            Text(title).font(.system(size: UIMetrics.isNarrow ? 30 : 36, weight: .bold))
                .lineLimit(2).minimumScaleFactor(0.6)
                .padding(.horizontal, 16).padding(.bottom, 6)
        }
        .frame(width: w, height: h)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

extension View {
    /// Без разделителя строки (iOS 15+; на iOS 14 разделители остаются).
    @ViewBuilder func listRowSeparatorHiddenCompat() -> some View {
        if #available(iOS 15.0, *) { self.listRowSeparator(.hidden) } else { self }
    }
}


/// Кнопки альбома как на Android: «Играть» (заливка), «Загрузить» (контур), сердце — альбом в библиотеке аккаунта.
struct AlbumButtonsRow: View {
    let tracks: [Track]
    let albumId: String
    let play: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    @State private var saved: Bool?
    @State private var confirmRemove = false
    @State private var shareFiles: [URL]?

    private var done: Int { tracks.filter { downloads.states[$0.id] == .done }.count }
    private var active: Int {
        tracks.filter {
            switch downloads.states[$0.id] {
            case .queued, .resolving, .downloading: return true
            default: return false
            }
        }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label(L("play"), systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(Color(.systemBackground))
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            if done == tracks.count && !tracks.isEmpty && active == 0 {
                // Всё скачано — как на Android: «удалить | отправить файлами (N)».
                HStack(spacing: 0) {
                    Button(action: { confirmRemove = true }) {
                        Image(systemName: "trash").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 24)
                    Button(action: { shareFiles = downloads.exportCopies(tracks) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrowshape.turn.up.right")
                            Text("\(tracks.count)")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .font(.subheadline.weight(.medium))
                .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: downloadTapped) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                        Text(active > 0 ? "\(done)/\(tracks.count)" : L("action_download"))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button(action: toggleSaved) {
                Image(systemName: saved == true ? "heart.fill" : "heart").font(.system(size: 22))
                    .foregroundColor(saved == true ? .accentColor : .primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(saved == nil)
        }
        .foregroundColor(.primary)
        .disabled(tracks.isEmpty)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .onAppear(perform: readSaved)
        .sheet(isPresented: Binding(get: { shareFiles != nil }, set: { if !$0 { shareFiles = nil } })) {
            ShareSheet(items: shareFiles ?? [])
        }
        .alert(isPresented: $confirmRemove) {
            Alert(title: Text(L("remove_download")),
                  primaryButton: .destructive(Text(L("ios_delete"))) { downloads.remove(tracks.map { $0.id }) },
                  secondaryButton: .cancel())
        }
    }

    private func downloadTapped() {
        if active > 0 { tracks.forEach { downloads.cancel($0.id) } }
        else if done == tracks.count { downloads.remove(tracks.map { $0.id }) }
        else { downloads.download(tracks) }
    }

    private func readSaved() {
        guard saved == nil else { return }
        let api = env.spotify, id = albumId
        Task {
            let on = (try? await api.isAlbumSaved(id)) ?? false
            await MainActor.run { saved = on }
        }
    }

    private func toggleSaved() {
        guard let on = saved else { return }
        saved = !on
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let api = env.spotify, id = albumId
        Task {
            do { try await api.setAlbumSaved(id, saved: !on) } catch { await MainActor.run { saved = on } }
        }
    }
}


/// Исполнители альбома маленькой строкой по центру; тап открывает исполнителя (первого или выбранного).
struct AlbumArtistsLine: View {
    let artists: [SpotifySimpleArtist]
    @State private var open: SpotifySimpleArtist?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                if i > 0 { Text(", ").foregroundColor(.secondary) }
                Text(a.name).foregroundColor(.secondary)
                    .onTapGesture { if let id = a.id, !id.isEmpty { open = a } }
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .background(NavigationLink(destination: SpotifyArtistScreen(artistId: open?.id ?? "", name: open?.name ?? ""),
                                   isActive: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) { EmptyView() }.opacity(0))
    }
}
