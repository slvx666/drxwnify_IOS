import SwiftUI

/// Главная (HOME-001…010, как `ui/screens/HomeScreen.kt`): «Для тебя» сеткой с кубиком, новинки подписок,
/// «Альбомы, до которых не дошли руки», «Похожее в жанре», что слушают друзья, «Твои жанры», забытые лайки,
/// свои миксы Spotify, остальная лента Spotify, «Глубже в каталог», «Похоже на …» в самом конце.
/// Новичку — стартовые подборки с сайта обзоров.
struct HomeScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HomeContent(settings: env.prefs.settings, feed: HomeFeed.shared, friends: env.friends)
            .rootTitle(L("home")) { TopBarIcons(together: $env.showTogether) }
    }
}

private struct HomeContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @ObservedObject var settings: TypedStore
    @ObservedObject var feed: HomeFeed
    @ObservedObject var friends: FriendsHub
    @StateObject private var model = HomeModel()
    @State private var openFriend: String?

    private var spotifyLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty }
    private var data: HomeFeedData? { feed.feed }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                sections
                if isEmpty { emptyState }
            }
            .padding(.vertical, 12)
            .miniPlayerInset()
        }
        .modifier(HomeRefresh { model.load(env, force: true) })
        .background(
            NavigationLink(destination: FriendScreen(pubkey: openFriend ?? ""),
                           isActive: Binding(get: { openFriend != nil }, set: { if !$0 { openFriend = nil } })) { EmptyView() }
        )
        .onAppear { model.load(env) }
        // Сменили основной аккаунт — главная собирается заново (Android 2.3.0 `HomeFeed.markStale`).
        .onReceive(MainAccount.shared.$revision.dropFirst()) { _ in model.load(env, force: true) }
        .onChange(of: settings.get(PK.spotifySpDc) ?? "") { _ in model.load(env, force: true) }
        // Восстановили копию (база заменена) — главная собирается заново, а не через 15 минут.
        .onReceive(env.database.$generation.dropFirst()) { _ in model.load(env, force: true) }
    }

    private var isEmpty: Bool {
        (model.forYou ?? []).isEmpty && model.starter == nil && model.spotifySections.isEmpty && model.newReleases.isEmpty &&
            (data?.similar ?? []).isEmpty && (data?.genreRows ?? []).isEmpty && (data?.unheardAlbums ?? []).isEmpty
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.house").font(.system(size: 40)).foregroundColor(.secondary)
            if model.loading {
                Text(L("home_empty_loading")).foregroundColor(.secondary)
                Text(L("home_empty_loading_hint")).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                ProgressView()
            } else {
                Text(L("home_empty_title")).foregroundColor(.secondary)
                Button(L("retry")) { model.load(env, force: true) }
            }
            if !spotifyLinked {
                NavigationLink(destination: SettingsScreen()) { Text(L("home_empty_connect_spotify")) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    @ViewBuilder private var sections: some View {
        let friendsRow = FriendListening.list(friends)
        if model.newcomer {
            if model.starter != nil, let grid = model.forYou, !grid.isEmpty {
                Text(L("starter_picks_note")).font(.caption).foregroundColor(.secondary).padding(.horizontal, 16)
                forYouSection(grid)
            }
            if let s = model.starter { starterSections(s) }
            if !friendsRow.isEmpty { friendsSection(friendsRow) }
        } else {
            if let grid = model.forYou, !grid.isEmpty { forYouSection(grid) }
            if !model.newReleases.isEmpty {
                section(L("home_new_releases")) { AlbumCardsRow(albums: model.newReleases, showAge: true) }
            }
            if let albums = data?.unheardAlbums, !albums.isEmpty {
                section(L("home_unheard_albums"), label: L("home_unheard_albums_label")) { AlbumCardsRow(albums: albums, showAge: false) }
            }
            ForEach(Array((data?.genreRows ?? []).enumerated()), id: \.offset) { _, row in
                section(L("home_more_in_genre", row.genre ?? ""), label: row.artist.isEmpty ? nil : L("home_more_in_genre_label", row.artist)) {
                    TrackCardsRow(tracks: row.tracks, title: row.genre ?? "")
                }
            }
            if !friendsRow.isEmpty { friendsSection(friendsRow) }
            if let genres = data?.genres, !genres.isEmpty {
                section(L("home_your_genres"), label: L("home_your_genres_label")) { GenreTilesRow(genres: genres) }
            }
            if let tracks = data?.forgotten, !tracks.isEmpty {
                section(L("home_forgotten"), label: L("home_forgotten_label")) { TrackCardsRow(tracks: tracks, title: L("home_forgotten")) }
            }
            if !model.mixes.isEmpty {
                section(L("home_mixes")) { SpotifyItemsRow(items: model.mixes) }
            }
            ForEach(model.spotifySections) { s in
                section(s.title ?? "") { SpotifyItemsRow(items: s.items) }
            }
            if let tracks = data?.deepCuts, !tracks.isEmpty {
                section(L("home_deep_cuts"), label: L("home_deep_cuts_label")) { TrackCardsRow(tracks: tracks, title: L("home_deep_cuts")) }
            }
            ForEach(Array((data?.similar ?? []).enumerated()), id: \.offset) { _, row in
                section(L("home_more_like", row.artist), image: row.image, artistId: row.artistId) {
                    TrackCardsRow(tracks: row.tracks, title: L("home_more_like", row.artist))
                }
            }
        }
    }

    // MARK: - Разделы

    private func forYouSection(_ grid: [SpotifyTrack]) -> some View {
        section(L("for_you")) {
            ForYouGrid(tracks: grid, starting: model.starting, play: { model.playFrom($0, env: env) }, dice: { model.dice(env) })
        }
    }

    @ViewBuilder private func starterSections(_ s: StarterPicks.Shown) -> some View {
        if !s.today.isEmpty {
            section(L("starter_today")) { AlbumCardsRow(albums: s.today, showAge: false) }
        }
        ForEach(Array(s.genreRows.enumerated()), id: \.offset) { _, row in
            section(L("home_more_in_genre", row.title)) { TrackCardsRow(tracks: row.tracks, title: row.title) }
        }
        ForEach(Array(s.artistRows.enumerated()), id: \.offset) { _, row in
            section(L("home_more_like", row.title)) { TrackCardsRow(tracks: row.tracks, title: row.title) }
        }
        if !s.artists.isEmpty {
            section(L("starter_artists")) { ArtistCirclesRow(artists: s.artists) }
        }
    }

    private func friendsSection(_ list: [FriendListening]) -> some View {
        section(L("home_friends_listening")) {
            FriendsListeningRow(entries: list, play: { e in player.play([e.track.track], title: e.name) }, open: { openFriend = $0.pubkey })
        }
    }

    /// Заголовок ряда как на Android: мелкая подпись сверху, крупный заголовок цветом акцента.
    private func section<Content: View>(_ title: String, label: String? = nil, image: String? = nil, artistId: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let artistId = artistId {
                    NavigationLink(destination: SpotifyArtistScreen(artistId: artistId, name: "")) {
                        ArtworkView(url: image, size: 36, circle: true, placeholderSymbol: "person.fill")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let label = label {
                        Text(label).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    Text(title).font(.title3.weight(.bold)).foregroundColor(.accentColor).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            content()
        }
    }
}

/// Жест «обновить» (на iOS 16+ — у `ScrollView`).
private struct HomeRefresh: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.refreshable { action() }
        } else {
            content
        }
    }
}

/// Ширина карточки ряда (136 pt на Android, меньше на узком экране).
private var cardWidth: CGFloat { UIMetrics.scaled(136) }

private func cover(_ t: SpotifyTrack) -> String? { t.album?.images.best(minWidth: 300) }

/// «Для тебя»: страницы 3×3, на первой девятая клетка — кубик (свежее радио). Тап по обложке — радио с неё.
struct ForYouGrid: View {
    let tracks: [SpotifyTrack]
    let starting: Bool
    let play: (SpotifyTrack) -> Void
    let dice: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @State private var page = 0

    private enum Cell: Hashable { case track(SpotifyTrack), dice }

    private var pages: [[Cell]] {
        var cells: [Cell] = tracks.prefix(ForYouRecommender.target).map { .track($0) }
        cells.insert(.dice, at: min(8, cells.count))
        return stride(from: 0, to: cells.count, by: 9).map { Array(cells[$0..<min(cells.count, $0 + 9)]) }
    }

    private static let spacing: CGFloat = 8
    private var side: CGFloat { UIMetrics.width - 32 }
    private var cell: CGFloat { ((side - Self.spacing * 2) / 3).rounded(.down) }
    private var height: CGFloat {
        let rows = pages.first.map { ($0.count + 2) / 3 } ?? 1
        return cell * CGFloat(rows) + Self.spacing * CGFloat(rows - 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, cells in
                    grid(cells)
                        .frame(width: side, height: height, alignment: .topLeading)
                        .tag(i)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .frame(height: height)
            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private func grid(_ cells: [Cell]) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(0..<((cells.count + 2) / 3), id: \.self) { r in
                HStack(spacing: Self.spacing) {
                    ForEach(Array(cells[(r * 3)..<min(cells.count, r * 3 + 3)].enumerated()), id: \.offset) { _, c in
                        view(c)
                    }
                }
            }
        }
    }

    @ViewBuilder private func view(_ c: Cell) -> some View {
        switch c {
        case .track(let t):
            ArtworkView(url: cover(t), size: cell, cornerRadius: 6)
                .overlay(player.current?.catalogId == t.id ? RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) : nil)
                .contentShape(Rectangle())
                .onTapGesture { play(t) }
                .onLongPressGesture { env.trackMenu = TrackMenuRequest(track: Track(t)) }
        case .dice:
            Button(action: dice) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3))
                    if starting {
                        ProgressView()
                    } else {
                        Image(systemName: "die.face.5.fill").font(.system(size: cell * 0.42)).foregroundColor(.accentColor)
                    }
                }
                .frame(width: cell, height: cell)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

/// Ряд обложек треков: тап играет ряд с этого трека, долгое нажатие — меню трека.
struct TrackCardsRow: View {
    let tracks: [SpotifyTrack]
    var title: String?
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController

    private var shown: [(offset: Int, element: SpotifyTrack)] {
        var seen = Set<String>()
        return Array(tracks.enumerated()).filter { seen.insert($0.element.id).inserted }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shown, id: \.element.id) { item in
                    card(item.element, index: item.offset)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func card(_ t: SpotifyTrack, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ArtworkView(url: cover(t), size: cardWidth, cornerRadius: 8)
            Text(t.name).font(.footnote.weight(.semibold)).lineLimit(1)
                .foregroundColor(player.current?.catalogId == t.id ? .accentColor : .primary)
            Text(t.artistNames).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { player.play(tracks.map { Track($0) }, startIndex: index, title: title, origin: .list) }
        .onLongPressGesture { env.trackMenu = TrackMenuRequest(track: Track(t)) }
    }
}

/// Ряд альбомов: обложка, название, тип и артист; у новинок — плашка «сегодня / вчера / N дн. назад».
struct AlbumCardsRow: View {
    let albums: [SpotifyAlbum]
    var showAge = true

    private var shown: [SpotifyAlbum] {
        var seen = Set<String>()
        return albums.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shown) { album in
                    NavigationLink(destination: SpotifyAlbumScreen(albumId: album.id, name: album.name)) {
                        VStack(alignment: .leading, spacing: 3) {
                            ArtworkView(url: album.images.best(minWidth: 300), size: cardWidth, cornerRadius: 8)
                                .overlay(ageBadge(album), alignment: .topLeading)
                            Text(album.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text(subtitle(album)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(width: cardWidth, alignment: .leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func ageBadge(_ album: SpotifyAlbum) -> some View {
        if showAge, let ago = Self.releasedAgo(album.releaseDate) {
            Text(ago).font(.caption2.weight(.semibold)).foregroundColor(Color(.systemBackground))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .padding(6)
        }
    }

    private func subtitle(_ a: SpotifyAlbum) -> String {
        var parts = [Self.releaseType(a)]
        if !showAge, let y = a.year, y.count == 4 { parts.append(y) }
        if !a.artistNames.isEmpty { parts.append(a.artistNames) }
        return parts.joined(separator: " · ")
    }

    static func releaseType(_ a: SpotifyAlbum) -> String {
        let type = (a.albumType ?? "").lowercased()
        if type == "single" { return L((4...7).contains(a.totalTracks) ? "home_type_ep" : "home_type_single") }
        if type == "ep" { return L("home_type_ep") }
        return L("home_type_album")
    }

    static func releasedAgo(_ date: String?) -> String? {
        guard let raw = date, raw.count >= 10 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let day = f.date(from: String(raw.prefix(10))) else { return nil }
        let cal = Calendar.current
        let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: Date())).day ?? 0)
        if days == 0 { return L("home_today") }
        if days == 1 { return L("home_yesterday") }
        if days < 14 { return L("home_days_ago", days) }
        if days < 60 { return L("home_weeks_ago", days / 7) }
        return L("home_months_ago", days / 30)
    }
}

/// Плитки жанров; каждая открывает жанровый плейлист (HOME-010).
struct GenreTilesRow: View {
    let genres: [String]

    private var shown: [String] {
        var seen = Set<String>()
        return genres.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(shown, id: \.self) { g in
                    NavigationLink(destination: GenreScreen(genre: g)) { tile(g) }
                        .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func tile(_ g: String) -> some View {
        let color = Self.color(g)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(gradient: Gradient(colors: [color, color.opacity(0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(g).font(.headline).foregroundColor(.white).lineLimit(2).padding(12)
        }
        .frame(width: UIMetrics.scaled(150), height: UIMetrics.scaled(88))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Цвет жанра: оттенок из имени семьи жанра.
    static func color(_ genre: String) -> Color {
        var h: UInt64 = 5381
        for b in Genres.family(genre).lowercased().utf8 { h = (h &* 33) &+ UInt64(b) }
        let hue: Double = Double(h % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

/// Ряд миксов и разделов ленты Spotify.
struct SpotifyItemsRow: View {
    let items: [SpotifyHomeItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: destination(item)) { card(item) }
                        .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func card(_ item: SpotifyHomeItem) -> some View {
        let artist = item.kind == .artist
        return VStack(alignment: artist ? .center : .leading, spacing: 3) {
            ArtworkView(url: item.imageUrl, size: cardWidth, cornerRadius: 8, circle: artist,
                        placeholderSymbol: artist ? "person.fill" : "music.note.list")
            Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1)
            if let sub = item.subtitle, !sub.isEmpty, !artist {
                Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .frame(width: cardWidth, alignment: artist ? .center : .leading)
    }

    @ViewBuilder private func destination(_ item: SpotifyHomeItem) -> some View {
        switch item.kind {
        case .playlist: SpotifyPlaylistScreen(playlistId: item.id, name: item.name, imageUrl: item.imageUrl)
        case .album: SpotifyAlbumScreen(albumId: item.id, name: item.name)
        case .artist: SpotifyArtistScreen(artistId: item.id, name: item.name)
        }
    }
}

/// Круглые фото артистов (главная новичка).
struct ArtistCirclesRow: View {
    let artists: [SpotifyArtist]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(artists) { a in
                    NavigationLink(destination: SpotifyArtistScreen(artistId: a.id, name: a.name)) {
                        VStack(spacing: 4) {
                            ArtworkView(url: a.images.best(minWidth: 300), size: UIMetrics.scaled(110), circle: true, placeholderSymbol: "person.fill")
                            Text(a.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                        .frame(width: UIMetrics.scaled(110))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Треки друзей: тап играет трек, долгое нажатие открывает друга.
struct FriendsListeningRow: View {
    let entries: [FriendListening]
    let play: (FriendListening) -> Void
    let open: (FriendListening) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(entries) { e in card(e) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func card(_ e: FriendListening) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ArtworkView(url: e.track.cover, size: cardWidth, cornerRadius: 8)
                .overlay(FriendAvatar(name: e.name, avatar: e.avatar, size: 30)
                            .padding(2).background(Circle().fill(Color(.systemBackground))).padding(6), alignment: .bottomLeading)
                .overlay(e.now ? Circle().fill(Color.green).frame(width: 10, height: 10).padding(8) : nil, alignment: .topTrailing)
            Text(e.track.title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(e.name + " · " + when(e)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { play(e) }
        .onLongPressGesture { open(e) }
    }

    private func when(_ e: FriendListening) -> String {
        if e.now { return L("home_friend_now") }
        let minutes = max(1, Int((FriendsHub.nowMs() - e.at) / 60_000))
        if minutes < 60 { return L("home_minutes_ago", minutes) }
        if minutes < 48 * 60 { return L("home_hours_ago", minutes / 60) }
        return L("home_days_ago", minutes / (24 * 60))
    }
}
