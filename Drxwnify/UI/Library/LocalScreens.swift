import SwiftUI

/// Список треков своей библиотеки: «Понравившиеся», «Топ», все треки (LIB-003, LIB-019).
struct LocalTrackListScreen: View {
    enum Kind {
        case liked, top, songs, downloaded
    }

    let kind: Kind
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        LocalTrackListContent(kind: kind, library: env.library)
    }
}

private struct LocalTrackListContent: View {
    let kind: LocalTrackListScreen.Kind
    @ObservedObject var library: LibraryStore
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    @State private var tracks: [Track] = []
    @State private var query = ""
    @State private var sort = SongSort.createDate
    @State private var descending = true

    private var title: String {
        switch kind {
        case .liked: return L("liked")
        case .top: return L("my_top")
        case .songs: return L("songs")
        case .downloaded: return L("downloaded_songs")
        }
    }

    private var shown: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return tracks }
        return tracks.filter { $0.title.lowercased().contains(q) || $0.artistNames.lowercased().contains(q) }
    }

    var body: some View {
        List {
            LibrarySearchField(text: $query)
            if kind == .songs { sortRow }
            if kind == .downloaded && !downloads.failures.isEmpty { FailedDownloadsSection() }
            Text(LPlural("n_song", shown.count)).font(.caption).foregroundColor(.secondary).listRowBackground(Color.clear)
            TrackPlayShuffleRow(tracks: shown, queueTitle: title)
            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, context: shown, index: i, queueTitle: title)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: library.revision) { _ in reload() }
        .onChange(of: downloads.revision) { _ in if kind == .downloaded { reload() } }
        .onChange(of: sort) { _ in reload() }
        .onChange(of: descending) { _ in reload() }
    }

    private var sortRow: some View {
        HStack {
            Menu {
                ForEach(SongSort.allCases, id: \.self) { s in
                    Button(action: { sort = s }) { Text(sortTitle(s)) }
                }
            } label: {
                Label(sortTitle(sort), systemImage: "arrow.up.arrow.down").font(.subheadline)
            }
            Spacer()
            Button(action: { descending.toggle() }) {
                Image(systemName: descending ? "arrow.down" : "arrow.up")
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .listRowBackground(Color.clear)
    }

    private func sortTitle(_ s: SongSort) -> String {
        switch s {
        case .createDate: return L("sort_by_create_date")
        case .name: return L("sort_by_name")
        case .artist: return L("sort_by_artist")
        case .playTime: return L("sort_by_play_time")
        }
    }

    private func reload() {
        if kind == .downloaded {
            tracks = downloads.downloadedTracks()
            return
        }
        let lib = library, k = kind, s = sort, d = descending
        DispatchQueue.global(qos: .userInitiated).async {
            let list: [Track]
            switch k {
            case .liked: list = lib.likedSongs()
            case .top: list = lib.topSongs(limit: Int(UserDefaults(suiteName: "ds.settings")?.string(forKey: "topSize") ?? "50") ?? 50)
            case .songs: list = lib.songs(sort: s, descending: d)
            case .downloaded: list = []
            }
            DispatchQueue.main.async { tracks = list }
        }
    }
}

/// Поле поиска по списку (LIB-028).
struct LibrarySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L("search"), text: $text).autocapitalization(.none).disableAutocorrection(true)
            if !text.isEmpty {
                Button(action: { text = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.secondary.opacity(0.18))
        .clipShape(Capsule())
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Свой плейлист (LIB-016): переименование, удаление, ручной порядок, удаление треков свайпом.
struct LocalPlaylistScreen: View {
    let playlist: LocalPlaylist
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        LocalPlaylistContent(playlist: playlist, library: env.library)
    }
}

private struct LocalPlaylistContent: View {
    let playlist: LocalPlaylist
    @ObservedObject var library: LibraryStore
    @Environment(\.presentationMode) private var presentation
    @State private var entries: [PlaylistEntry] = []
    @State private var name = ""
    @State private var editing = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var query = ""

    private var shown: [PlaylistEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return entries }
        return entries.filter { $0.track.title.lowercased().contains(q) || $0.track.artistNames.lowercased().contains(q) }
    }

    var body: some View {
        List {
            VStack(spacing: 10) {
                PlaylistCover(playlist: LocalPlaylist(id: playlist.id, name: name, songCount: entries.count,
                                                      thumbnails: Array(entries.compactMap { $0.track.artworkUrl }.prefix(4)),
                                                      thumbnailUrl: nil, isEditable: playlist.isEditable), size: UIMetrics.scaled(170))
                if renaming {
                    TextField(L("playlist_name"), text: $name, onCommit: commitRename)
                        .multilineTextAlignment(.center)
                        .font(.title3.weight(.bold))
                } else {
                    Text(name).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                }
                Text(LPlural("n_song", entries.count)).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)

            TrackPlayShuffleRow(tracks: shown.map { $0.track }, queueTitle: name)
            if entries.count > 8 && !editing { LibrarySearchField(text: $query) }
            ForEach(shown) { entry in
                TrackRow(track: entry.track, context: shown.map { $0.track },
                         index: shown.firstIndex(of: entry) ?? 0, queueTitle: name,
                         removeTitle: playlist.isEditable ? L("remove_from_playlist") : nil,
                         onRemove: { library.remove(entry: entry.id, from: playlist.id) })
            }
            .onDelete { offsets in
                for i in offsets where shown.indices.contains(i) { library.remove(entry: shown[i].id, from: playlist.id) }
            }
            .onMove { source, destination in
                var list = entries
                list.move(fromOffsets: source, toOffset: destination)
                entries = list
                library.reorder(playlist.id, order: list.map { $0.id })
            }
            .deleteDisabled(!playlist.isEditable)
            .moveDisabled(!editing || !query.isEmpty)
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing: Menu {
            if playlist.isEditable {
                Button(action: { editing.toggle() }) {
                    Label(L(editing ? "ios_done" : "sort_by_custom"), systemImage: editing ? "checkmark" : "arrow.up.arrow.down")
                }
                Button(action: { renaming = true }) { Label(L("edit_playlist"), systemImage: "pencil") }
            }
            Button(action: { confirmDelete = true }) { Label(L("delete"), systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
        })
        .alert(isPresented: $confirmDelete) {
            Alert(title: Text(L("delete_playlist_confirm", name)),
                  primaryButton: .destructive(Text(L("delete"))) {
                      library.deletePlaylist(playlist.id)
                      presentation.wrappedValue.dismiss()
                  },
                  secondaryButton: .cancel(Text(L("cancel"))))
        }
        .onAppear {
            if name.isEmpty { name = playlist.name }
            reload()
        }
        .onChange(of: library.revision) { _ in reload() }
    }

    private func commitRename() {
        renaming = false
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { name = playlist.name } else { library.renamePlaylist(playlist.id, name: n) }
    }

    private func reload() {
        let lib = library, id = playlist.id
        DispatchQueue.global(qos: .userInitiated).async {
            let list = lib.playlistEntries(id)
            DispatchQueue.main.async { entries = list }
        }
    }
}

/// История прослушиваний по дням (сегодня, вчера, на этой неделе…).
struct HistoryScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HistoryContent(library: env.library)
    }
}

private struct HistoryContent: View {
    @ObservedObject var library: LibraryStore
    @State private var entries: [HistoryEntry] = []

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            let diff = cal.dateComponents([.day], from: day, to: today).day ?? 0
            let key: String
            if diff <= 0 { key = L("today") }
            else if diff == 1 { key = L("yesterday") }
            else if diff < 7 { key = L("this_week") }
            else if diff < 14 { key = L("last_week") }
            else { key = formatter.string(from: day) }
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { title, items in
                Section(header: Text(title)) {
                    ForEach(items) { e in
                        TrackRow(track: e.track, context: items.map { $0.track }, index: items.firstIndex(of: e) ?? 0, queueTitle: L("history"),
                                 removeTitle: L("remove_from_history"), onRemove: { library.removeHistory(e.id) })
                    }
                    .onDelete { offsets in
                        for i in offsets where items.indices.contains(i) { library.removeHistory(items[i].id) }
                    }
                }
            }
            if entries.isEmpty {
                Text(L("ios_history_empty")).foregroundColor(.secondary).listRowBackground(Color.clear)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(L("history"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: library.revision) { _ in reload() }
    }

    private func reload() {
        let lib = library
        DispatchQueue.global(qos: .userInitiated).async {
            let list = lib.history()
            DispatchQueue.main.async { entries = list }
        }
    }
}

/// Локальный артист: его треки из своей библиотеки и переход на страницу каталога, если она известна.
struct LocalArtistScreen: View {
    let artist: LocalArtist
    @EnvironmentObject private var env: AppEnvironment
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            SpotifyHeader(imageUrl: artist.thumbnailUrl, title: artist.name, detail: LPlural("n_song", tracks.count), circle: true)
            if let id = artist.spotifyId ?? (artist.id.hasPrefix("LA") || artist.id.hasPrefix("UC") ? nil : artist.id) {
                NavigationLink(destination: SpotifyArtistScreen(artistId: id, name: artist.name)) {
                    Label(L("view_artist"), systemImage: "person")
                }
            }
            TrackPlayShuffleRow(tracks: tracks, queueTitle: artist.name)
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, context: tracks, index: i, queueTitle: artist.name)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tracks = env.library.artistSongs(artist.id) }
    }
}

/// «Почему не скачались» (DL-008): треки и причина у каждой, «Повторить все» и «Очистить».
struct FailedDownloadsSection: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(downloads.failures) { f in
                HStack(alignment: .top, spacing: 10) {
                    ArtworkView(url: f.track.artworkUrl, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.track.title).lineLimit(1)
                        Text(f.track.artistNames).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Text(f.reason).font(.caption).foregroundColor(.orange)
                    }
                }
            }
            HStack {
                Button(L("ios_retry_all")) { downloads.retryFailed() }.buttonStyle(BorderlessButtonStyle())
                Spacer()
                Button(L("ios_clear")) { downloads.clearFailures() }.buttonStyle(BorderlessButtonStyle()).foregroundColor(.secondary)
            }
        } label: {
            Label(L("download_issues_why", downloads.failures.count), systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
        }
    }
}
