import SwiftUI

/// Жанровый плейлист (`ui/screens/GenreScreen.kt`, HOME-010): 15 треков, лучше всего описывающих жанр, по тегам Last.fm.
struct GenreScreen: View {
    let genre: String
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var loader = Loader<[SpotifyTrack]>()

    var body: some View {
        List {
            VStack(spacing: 8) {
                ZStack {
                    LinearGradient(gradient: Gradient(colors: [GenreTilesRow.color(genre), GenreTilesRow.color(genre).opacity(0.4)]),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(genre).font(.title.weight(.bold)).foregroundColor(.white).multilineTextAlignment(.center).padding(16)
                }
                .frame(width: UIMetrics.scaled(200), height: UIMetrics.scaled(200))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(L("genre_playlist_subtitle", GenrePlaylists.size)).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                Text(L("genre_playlist_source")).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            if let tracks = loader.value, !tracks.isEmpty {
                PlayShuffleRow(tracks: tracks, queueTitle: genre)
                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                    SpotifyTrackRow(track: t, context: tracks, index: i, queueTitle: genre, origin: .list)
                }
            } else if case .failed = loader.state {
                LoadStatusRow(isLoading: false, error: L("genre_playlist_failed"), retry: { load(force: true) })
            } else if loader.value != nil {
                LoadStatusRow(isLoading: false, error: L("genre_playlist_failed"), retry: { load(force: true) })
            } else {
                LoadStatusRow(isLoading: true, error: nil, retry: {})
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let g = genre
        loader.load(force: force) {
            await GenrePlaylists.shared.configure(api)
            return try await GenrePlaylists.shared.tracks(g, force: force)
        }
    }
}
