import SwiftUI

/// Полноэкранные «Новые релизы альбомов» с вкладками «Для тебя / Подписки / Открытия»
/// (Android: `ui/screens/NewReleaseScreen.kt` + `viewmodels/NewReleaseViewModel.kt`).
///
/// Вкладки как на Android: «Подписки» — релизы исполнителей с подпиской (`artist.bookmarkedAt`),
/// «Открытия» — остальные, «Для тебя» — всё вместе.
struct NewReleasesScreen: View {
    private var env: AppEnvironment { AppEnvironment.shared }
    @StateObject private var model = NewReleasesModel()
    @State private var tab: NewReleasesModel.Tab = .forYou

    private var albums: [SpotifyAlbum] {
        switch tab {
        case .forYou: return model.forYou
        case .following: return model.following
        case .discover: return model.discover
        }
    }

    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }

    private var cardWidth: CGFloat { (UIScreen.main.bounds.width - 16 * 2 - 12) / 2 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ChipBar(items: [
                    .init(id: NewReleasesModel.Tab.forYou.rawValue, title: L("new_releases_for_you")),
                    .init(id: NewReleasesModel.Tab.following.rawValue, title: "\(L("new_releases_following")) (\(model.following.count))"),
                    .init(id: NewReleasesModel.Tab.discover.rawValue, title: "\(L("new_releases_discover")) (\(model.discover.count))"),
                ], selected: tab.rawValue) { id in
                    if let t = NewReleasesModel.Tab(rawValue: id) { tab = t }
                }
                .frame(height: 34)

                if albums.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(destination: SpotifyAlbumScreen(albumId: album.id, name: album.name)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ArtworkView(url: album.images.best(minWidth: 300), size: cardWidth, cornerRadius: 8)
                                    Text(album.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                    Text(subtitle(album)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if model.canLoadMore {
                    HStack {
                        Spacer()
                        Button(L("action_download")) { model.loadMore(env) }
                            .font(.subheadline.weight(.medium))
                            .disabled(model.loading)
                        if model.loading { ProgressView() }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
            .miniPlayerInset()
        }
        .background(AppTheme.rowBackground.ignoresSafeArea())
        .navigationTitle(L("new_release_albums"))
        .onAppear { model.load(env) }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 36)).foregroundColor(.secondary)
            if model.loading {
                ProgressView()
            } else if model.failed {
                Text(L("ios_newreleases_error")).foregroundColor(.secondary)
                Button(L("retry")) { model.loadMore(env) }
            } else {
                Text(emptyText).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptyText: String {
        switch tab {
        case .forYou: return L("ios_newreleases_empty")
        case .following: return L("ios_newreleases_empty_following")
        case .discover: return L("ios_newreleases_empty_discover")
        }
    }

    private func subtitle(_ a: SpotifyAlbum) -> String {
        var parts: [String] = []
        if !a.artistNames.isEmpty { parts.append(a.artistNames) }
        if let y = a.year, y.count == 4 { parts.append(y) }
        return parts.joined(separator: " • ")
    }
}

/// Загрузка и раскладка новинок по вкладкам.
@MainActor
final class NewReleasesModel: ObservableObject {
    enum Tab: String { case forYou, following, discover }

    @Published private(set) var forYou: [SpotifyAlbum] = []
    @Published private(set) var following: [SpotifyAlbum] = []
    @Published private(set) var discover: [SpotifyAlbum] = []
    @Published private(set) var loading = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var failed = false

    private var items: [SpotifyAlbum] = []
    private var offset = 0

    func load(_ env: AppEnvironment) {
        guard items.isEmpty else { return }
        loadMore(env)
    }

    func loadMore(_ env: AppEnvironment) {
        guard !loading else { return }
        loading = true
        failed = false
        let offset = self.offset
        Task {
            let api = env.spotify
            let keys = env.library.subscribedArtistKeys()
            var page: SpotifyPaging<SpotifyAlbum>?
            if let p = try? await api.newReleases(limit: 50, offset: offset) { page = p }
            else if offset == 0, let p = try? await api.newReleases(limit: 20) { page = p }
            guard let page else {
                self.loading = false
                self.failed = self.items.isEmpty
                return
            }
            var seen = Set(self.items.map(\.id))
            self.items += page.items.filter { seen.insert($0.id).inserted }
            self.offset = self.items.count
            self.canLoadMore = self.items.count < page.total && !page.items.isEmpty
            self.loading = false
            self.split(keys)
        }
    }

    private func split(_ keys: Set<String>) {
        let sorted = items.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        following = sorted.filter { Self.isSubscribed($0, keys: keys) }
        discover = sorted.filter { !Self.isSubscribed($0, keys: keys) }
        forYou = sorted
    }

    private static func isSubscribed(_ album: SpotifyAlbum, keys: Set<String>) -> Bool {
        album.artists.contains { a in
            (a.id.map { keys.contains($0) } ?? false) || keys.contains(a.name.lowercased())
        }
    }
}
