import SwiftUI

/// «drxwnslvt's» — альбомы, разобранные в канале разработчика, с оценкой (Android `reviews/ReviewsContent`).
/// Видно только тем, кого разработчик отметил (красная метка).
struct ReviewsSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var reviews: [NightReviews.Review] = []
    @State private var opening: String?
    @State private var openAlbum: (id: String, name: String)?

    var body: some View {
        Group {
            if reviews.isEmpty {
                LoadStatusRow(isLoading: true, error: nil, retry: {})
            }
            ForEach(reviews, id: \.id) { r in
                Button(action: { open(r) }) {
                    HStack(spacing: 12) {
                        Text(String(format: r.rating.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", r.rating))
                            .font(.headline.monospacedDigit())
                            .foregroundColor(Color(.systemBackground))
                            .frame(width: 46, height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.album).lineLimit(1).foregroundColor(.primary)
                            Text([r.artist, r.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            if !r.mainGenres.isEmpty {
                                Text(r.mainGenres.prefix(3).joined(separator: ", ")).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if opening == r.id { ProgressView() }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .themedRow()
            }
        }
        .background(NavigationLink(destination: SpotifyAlbumScreen(albumId: openAlbum?.id ?? "", name: openAlbum?.name ?? ""),
                                   isActive: Binding(get: { openAlbum != nil }, set: { if !$0 { openAlbum = nil } })) { EmptyView() }.opacity(0))
        .onAppear(perform: load)
    }

    private func load() {
        guard reviews.isEmpty else { return }
        Task {
            let list = await NightReviews.shared.offline()
            await MainActor.run { reviews = list }
            await NightReviews.shared.refreshOnce()
            let fresh = await NightReviews.shared.offline()
            await MainActor.run { if !fresh.isEmpty { reviews = fresh } }
        }
    }

    private func open(_ r: NightReviews.Review) {
        opening = r.id
        let api = env.spotify
        Task {
            let id = await NightReviews.shared.findAlbum(r, api: api)
            await MainActor.run {
                opening = nil
                if let id = id { openAlbum = (id, r.album) }
            }
        }
    }
}

/// «VK»: своя музыка аккаунта VK — треки, альбомы, плейлисты (Android `VkLibraryChips`).
struct VkLibrarySection: View {
    let vk: VkProvider
    private enum Part: String, CaseIterable { case tracks, albums, playlists }
    @State private var part = Part.tracks
    @State private var tracks: [Track] = []
    @State private var lists: [VkProvider.VkPlaylist] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            HStack(spacing: 8) {
                ForEach(Part.allCases, id: \.self) { p in
                    Button(action: { part = p }) {
                        Text(title(p)).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(height: 32)
                            .foregroundColor(part == p ? Color(.systemBackground) : .primary)
                            .background(Capsule().fill(part == p ? Color.accentColor : Color.secondary.opacity(0.22)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .listRowBackground(Color.clear)
            if loading { LoadStatusRow(isLoading: true, error: nil, retry: {}) }
            if let e = error { LoadStatusRow(isLoading: false, error: e, retry: { load(force: true) }) }
            switch part {
            case .tracks:
                if !tracks.isEmpty { TrackPlayShuffleRow(tracks: tracks, queueTitle: "VK") }
                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, context: tracks, index: i, queueTitle: "VK")
                }
            case .albums, .playlists:
                ForEach(lists.filter { (part == .albums) == $0.isAlbum }) { pl in
                    NavigationLink(destination: VkPlaylistScreen(vk: vk, playlist: pl)) {
                        HStack(spacing: 12) {
                            ArtworkView(url: pl.thumb, size: 52, placeholderSymbol: "music.note.list")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pl.title).lineLimit(1)
                                Text([pl.subtitle.isEmpty ? nil : pl.subtitle, LPlural("n_song", pl.count)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .themedRow()
                }
            }
        }
        .onAppear { load(force: false) }
    }

    private func title(_ p: Part) -> String {
        switch p {
        case .tracks: return L("filter_songs")
        case .albums: return L("filter_albums")
        case .playlists: return L("filter_playlists")
        }
    }

    private func load(force: Bool) {
        guard force || (tracks.isEmpty && lists.isEmpty), !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                async let t = vk.myTracks()
                async let l = vk.myPlaylists()
                let (tt, ll) = try await (t, l)
                await MainActor.run { tracks = tt; lists = ll; loading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; loading = false }
            }
        }
    }
}

/// Альбом или плейлист VK.
struct VkPlaylistScreen: View {
    let vk: VkProvider
    let playlist: VkProvider.VkPlaylist
    @State private var tracks: [Track] = []
    @State private var loading = true

    var body: some View {
        List {
            VStack(spacing: 6) {
                ArtworkView(url: playlist.thumb, size: min(220, UIMetrics.width * 0.6), cornerRadius: 10, placeholderSymbol: "music.note.list")
                Text(playlist.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                if !playlist.subtitle.isEmpty { Text(playlist.subtitle).font(.subheadline).foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .listRowBackground(Color.clear)
            if !tracks.isEmpty { TrackPlayShuffleRow(tracks: tracks, queueTitle: playlist.title) }
            if loading { LoadStatusRow(isLoading: true, error: nil, retry: {}) }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, context: tracks, index: i, queueTitle: playlist.title)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard tracks.isEmpty else { return }
            Task {
                let t = (try? await vk.playlistTracks(playlist)) ?? []
                await MainActor.run { tracks = t; loading = false }
            }
        }
    }
}
