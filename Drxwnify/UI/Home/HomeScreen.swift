import SwiftUI

/// Главная: персональная лента Spotify (миксы, новинки, «вернуться к…») горизонтальными полками.
/// Локальные подборки («Быстрый выбор» и др.) добавятся на этапе 9.
struct HomeScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HomeContent(settings: env.prefs.settings)
            .navigationTitle(L("home"))
            .navigationBarItems(trailing: NavigationLink(destination: SettingsScreen()) {
                Image(systemName: "gearshape")
            })
    }
}

private struct HomeContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @StateObject private var loader = Loader<SpotifyHomeFeed>()
    @State private var loadedFor = ""

    private var account: String { (settings.get(PK.spotifySpDc) ?? "").isEmpty ? "" : (settings.get(PK.spotifyUserId) ?? "linked") }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if account.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.house").font(.system(size: 40)).foregroundColor(.secondary)
                        Text(L("spotify_not_logged_in")).foregroundColor(.secondary)
                        NavigationLink(destination: SettingsScreen()) { Text(L("spotify_login")) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if let feed = loader.value {
                    if let greeting = feed.greeting, !greeting.isEmpty {
                        Text(greeting).font(.title2.weight(.bold)).padding(.horizontal, 16)
                    }
                    ForEach(feed.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = section.title, !title.isEmpty {
                                Text(title).font(.title3.weight(.bold)).padding(.horizontal, 16)
                            }
                            shelf(section.items)
                        }
                    }
                } else {
                    LoadStatusRow(isLoading: loader.isLoading, error: failure, retry: { load(force: true) })
                        .padding(16)
                }
            }
            .padding(.vertical, 12)
            .miniPlayerInset()
        }
        .onAppear { load(force: false) }
        .onChange(of: account) { _ in load(force: true) }
    }

    private var failure: String? {
        if case .failed(let message) = loader.state { return message }
        return nil
    }

    private func shelf(_ items: [SpotifyHomeItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: destination(item)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(url: item.imageUrl, size: 140, cornerRadius: 10, circle: item.kind == .artist,
                                        placeholderSymbol: item.kind == .artist ? "person.fill" : "music.note.list")
                            Text(item.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                .frame(width: 140, alignment: item.kind == .artist ? .center : .leading)
                            if let sub = item.subtitle, !sub.isEmpty {
                                Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private func destination(_ item: SpotifyHomeItem) -> some View {
        switch item.kind {
        case .playlist: SpotifyPlaylistScreen(playlistId: item.id, name: item.name, imageUrl: item.imageUrl)
        case .album: SpotifyAlbumScreen(albumId: item.id, name: item.name)
        case .artist: SpotifyArtistScreen(artistId: item.id, name: item.name)
        }
    }

    private func load(force: Bool) {
        guard !account.isEmpty else { return }
        if !force && loadedFor == account && loader.value != nil { return }
        loadedFor = account
        let api = env.spotify
        loader.load(force: force) { try await api.home() }
    }
}
