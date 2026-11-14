import SwiftUI

/// Перенос из другого привязанного аккаунта в основной (Android 2.3.0 `AccountTransfer`): медленно, по одному
/// (пауза 700 мс, до 5000 треков). Плейлист копируется в приложение (играет сразу) и потом создаётся в основном аккаунте
/// в фоне (`RemotePlaylists`); альбом ищется в каталоге основного и сохраняется; трек ищется и лайкается.
final class AccountTransfer: ObservableObject {
    struct Progress {
        var from: CatalogSource
        var to: CatalogSource
        var total: Int
        var done = 0
        var missing: [String] = []
        var finished = false
    }

    static let shared = AccountTransfer()
    @Published private(set) var progress: Progress?
    var isRunning: Bool { progress?.finished == false }

    func clear() { if progress?.finished == true { progress = nil } }

    func start(env: AppEnvironment, from: CatalogSource, playlists: [SpotifyLibraryEntry], albums: [SpotifyLibraryEntry], tracks: [SpotifyTrack]) {
        guard let to = MainAccount.shared.main, !isRunning else { return }
        progress = Progress(from: from, to: to, total: playlists.count + albums.count + tracks.count)
        let api = env.spotify, library = env.library
        Task {
            var missing: [String] = []
            func step() async {
                let m = missing
                await MainActor.run { self.progress?.done += 1; self.progress?.missing = m }
            }
            var localIds: [String] = []
            for e in playlists {
                if let id = await Self.copyPlaylist(e, api: api, library: library) { localIds.append(id) } else { missing.append(e.name) }
                await step()
            }
            if !localIds.isEmpty {
                await MainActor.run {
                    localIds.forEach { RemotePlaylists.shared.markImported($0) }
                    if RemotePlaylists.shared.canCreate(to) { RemotePlaylists.shared.push(localIds, to: to) }
                }
            }
            for e in albums {
                let id = CatalogSource.of(e.id) == to ? e.id : await Self.albumIn(to, name: e.name, creator: e.creator, api: api)
                if let id = id, (try? await api.setAlbumSaved(id, saved: true)) != nil {
                } else {
                    missing.append([e.creator, e.name].compactMap { $0 }.joined(separator: " – "))
                }
                await step()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            for t in tracks {
                let track = Track(t)
                if let id = await CrossCatalog.trackFor(to, track: track, api: api), (try? await api.saveTrack(id)) != nil {
                    await MainActor.run { env.likes.markLiked([id]) }
                } else {
                    missing.append([t.artists.first?.name, t.name].compactMap { $0 }.joined(separator: " – "))
                }
                await step()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            let m = missing
            await MainActor.run { self.progress?.finished = true; self.progress?.missing = m }
        }
    }

    /// Плейлист другого аккаунта — своим плейлистом в приложении; id своего плейлиста.
    private static func copyPlaylist(_ e: SpotifyLibraryEntry, api: SpotifyAPI, library: LibraryStore) async -> String? {
        var tracks: [Track] = []
        var offset = 0
        while offset < 5000 {
            guard let page = try? await api.playlistTracks(e.id, limit: 100, offset: offset) else { break }
            tracks += page.items.map { $0.track }.filter { !$0.isLocal && !$0.id.isEmpty }.map { Track($0) }
            offset += 100
            if page.items.isEmpty || offset >= page.total { break }
        }
        guard !tracks.isEmpty else { return nil }
        let list = tracks
        return await MainActor.run {
            let id = library.createPlaylist(name: e.name)
            library.add(list, to: id)
            return id
        }
    }

    /// Тот же альбом в каталоге `target` (поиск, нестрогое сравнение как у галочки «уже в …»).
    static func albumIn(_ target: CatalogSource, name: String, creator: String?, api: SpotifyAPI) async -> String? {
        let q = [creator?.components(separatedBy: ", ").first, name].compactMap { $0 }.joined(separator: " ")
        guard let r = try? await api.searchIn(target, q, limit: 10) else { return nil }
        let key = AlbumMatch.key(name, creator)
        return r.albums.first { AlbumMatch.same(key, AlbumMatch.key($0.name, $0.artistNames)) }?.id
    }
}

/// Нестрогое сравнение альбомов (Android 2.3.0): «Artist - Title (2024)» в названии плейлиста ВК, «(Deluxe)», год.
enum AlbumMatch {
    struct Key: Hashable {
        var artist: String
        var title: String
    }

    static func key(_ name: String, _ creator: String?) -> Key {
        var artist = creator.flatMap { c in
            [", ", " & ", " feat. "].reduce(c) { acc, sep in acc.components(separatedBy: sep).first ?? acc }
        }?.trimmingCharacters(in: .whitespaces) ?? ""
        var title = name
        if let r = name.range(of: #"\s[-–—]\s"#, options: .regularExpression) {
            let before = String(name[..<r.lowerBound])
            if artist.isEmpty || fold(before) == fold(artist) {
                artist = before
                title = String(name[r.upperBound...])
            }
        }
        return Key(artist: fold(artist), title: foldTitle(title))
    }

    static func fold(_ t: String) -> String {
        String(t.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
    }

    static func foldTitle(_ t: String) -> String {
        var s = t.lowercased()
        s = s.replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(deluxe|edition|remaster(ed)?|expanded|version|ep|single|lp)\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(19|20)\d{2}\b"#, with: " ", options: .regularExpression)
        return fold(s)
    }

    /// Та же запись: то же название (или одно начинается с другого у длинных) у того же исполнителя.
    static func same(_ a: Key, _ b: Key) -> Bool {
        if a.title.isEmpty || b.title.isEmpty { return false }
        let titleOk = a.title == b.title || (min(a.title.count, b.title.count) >= 5 && (a.title.hasPrefix(b.title) || b.title.hasPrefix(a.title)))
        if !titleOk { return false }
        if a.artist.isEmpty || b.artist.isEmpty { return a.title == b.title }
        return a.artist == b.artist || a.artist.contains(b.artist) || b.artist.contains(a.artist)
    }
}

/// Списки для переноса: в памяти 15 мин и на диске — показываются сразу, свежие подгружаются следом.
private struct TransferLists: Codable {
    var at: Date
    var entries: [SpotifyLibraryEntry]
    var tracks: [SpotifyTrack]
    var mainAlbums: [String]
}

private var transferMemory: [String: TransferLists] = [:]

struct AccountTransferScreen: View {
    let from: CatalogSource
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var transfer = AccountTransfer.shared
    private enum Tab: String, CaseIterable { case playlists, albums, tracks }
    @State private var tab = Tab.playlists
    @State private var query = ""
    @State private var loading = true
    @State private var entries: [SpotifyLibraryEntry] = []
    @State private var tracks: [SpotifyTrack] = []
    @State private var mainAlbums: [AlbumMatch.Key] = []
    @State private var pickedPlaylists = Set<String>()
    @State private var pickedAlbums = Set<String>()
    @State private var pickedTracks = Set<String>()

    private var main: CatalogSource? { MainAccount.shared.main }

    private struct Row: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var image: String?
        var already = false
    }

    private var already: Set<String> {
        Set(entries.filter { $0.kind == .album }.filter { e in
            let k = AlbumMatch.key(e.name, e.creator)
            return mainAlbums.contains { AlbumMatch.same(k, $0) }
        }.map { $0.id })
    }

    private func matches(_ texts: String?...) -> Bool {
        let n = query.trimmingCharacters(in: .whitespaces).lowercased()
        return n.isEmpty || texts.contains { $0?.lowercased().contains(n) == true }
    }

    private var rows: [Row] {
        switch tab {
        case .tracks:
            return tracks.filter { matches($0.name, $0.artistNames) }.map { Row(id: $0.id, title: $0.name, subtitle: $0.artistNames, image: $0.album?.images.first?.url) }
        case .albums:
            let have = already
            return entries.filter { $0.kind == .album && matches($0.name, $0.creator) }
                .map { Row(id: $0.id, title: $0.name, subtitle: $0.creator, image: $0.imageUrl, already: have.contains($0.id)) }
        case .playlists:
            return entries.filter { $0.kind == .playlist && matches($0.name, $0.creator) }.map { Row(id: $0.id, title: $0.name, subtitle: $0.creator, image: $0.imageUrl) }
        }
    }

    private var picked: Set<String> {
        switch tab {
        case .tracks: return pickedTracks
        case .albums: return pickedAlbums
        case .playlists: return pickedPlaylists
        }
    }

    private func setPicked(_ v: Set<String>) {
        switch tab {
        case .tracks: pickedTracks = v
        case .albums: pickedAlbums = v
        case .playlists: pickedPlaylists = v
        }
    }

    private func title(_ t: Tab) -> String {
        let (key, n): (String, Int) = {
            switch t {
            case .playlists: return ("filter_playlists", pickedPlaylists.count)
            case .albums: return ("filter_albums", pickedAlbums.count)
            case .tracks: return ("vk_tab_tracks", pickedTracks.count)
            }
        }()
        return L(key) + (n > 0 ? " (\(n))" : "")
    }

    var body: some View {
        Group {
            if let p = transfer.progress, p.from == from {
                progressView(p)
            } else if main == nil || main == from {
                List { Text(L("transfer_no_main")) }
            } else {
                picker
            }
        }
        .navigationTitle(L("transfer_from_to", from.title, (main ?? from).title))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            transfer.clear()
            load()
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            List {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .listRowBackground(Color.clear)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(L("search"), text: $query)
                }
                HStack {
                    let all = !rows.isEmpty && rows.allSatisfy { picked.contains($0.id) }
                    Button(L(all ? "transfer_pick_none" : "transfer_pick_all")) {
                        let keys = Set(rows.map { $0.id })
                        setPicked(all ? picked.subtracting(keys) : picked.union(keys))
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    Spacer()
                    Text(LPlural("transfer_found", rows.count)).font(.caption).foregroundColor(.secondary)
                }
                if loading && rows.isEmpty {
                    LoadStatusRow(isLoading: true, error: nil, retry: {})
                }
                ForEach(rows) { row in
                    Button(action: {
                        var p = picked
                        if p.contains(row.id) { p.remove(row.id) } else { p.insert(row.id) }
                        setPicked(p)
                    }) {
                        HStack(spacing: 12) {
                            ArtworkView(url: row.image, size: 48, placeholderSymbol: "music.note")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).foregroundColor(.primary).lineLimit(1)
                                if let s = row.subtitle { Text(s).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                                if row.already, let m = main {
                                    Label(L("transfer_already_in", m.title), systemImage: "checkmark")
                                        .font(.caption.weight(.medium)).foregroundColor(.green)
                                }
                            }
                            Spacer()
                            Image(systemName: picked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(picked.contains(row.id) ? .accentColor : .secondary)
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            VStack(spacing: 8) {
                Text(L("transfer_picked", pickedPlaylists.count, pickedAlbums.count, pickedTracks.count)).font(.subheadline)
                Button(action: start) {
                    Text(L("transfer_start", (main ?? from).title)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(BorderedProminentCompat())
                .disabled(pickedPlaylists.count + pickedAlbums.count + pickedTracks.count == 0)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .miniPlayerInset()
        }
    }

    private func progressView(_ p: AccountTransfer.Progress) -> some View {
        List {
            Section {
                Text(L(p.finished ? "transfer_done" : "transfer_running", p.done, p.total)).font(.headline)
                ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                Text(L("transfer_playlists_later")).font(.caption).foregroundColor(.secondary)
            }
            if !p.missing.isEmpty {
                Section(header: Text(LPlural("transfer_missing", p.missing.count))) {
                    Text(p.missing.joined(separator: "\n")).font(.caption).foregroundColor(.secondary)
                }
            }
            if p.finished {
                Button(L("transfer_again")) { transfer.clear() }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    private func start() {
        transferMemory.removeAll()
        transfer.start(env: env, from: from,
                       playlists: entries.filter { $0.kind == .playlist && pickedPlaylists.contains($0.id) },
                       albums: entries.filter { $0.kind == .album && pickedAlbums.contains($0.id) },
                       tracks: tracks.filter { pickedTracks.contains($0.id) })
    }

    private static func file(_ key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transfer_" + key.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression) + ".json")
    }

    private func show(_ c: TransferLists) {
        entries = c.entries
        tracks = c.tracks
        mainAlbums = c.mainAlbums.map { s in
            let parts = s.components(separatedBy: "|")
            return AlbumMatch.Key(artist: parts.first ?? "", title: parts.count > 1 ? parts[1] : "")
        }
        loading = false
    }

    private func load() {
        let key = "\(from.rawValue)>\(main?.rawValue ?? "")"
        if let m = transferMemory[key], Date().timeIntervalSince(m.at) < 15 * 60 { show(m); return }
        let saved = transferMemory[key] ?? (try? Data(contentsOf: Self.file(key))).flatMap { try? JSONDecoder().decode(TransferLists.self, from: $0) }
        if let s = saved { show(s) }
        if let s = saved, Date().timeIntervalSince(s.at) < 15 * 60 { transferMemory[key] = s; return }
        let api = env.spotify, src = from, m = main
        Task {
            let all = (try? await api.libraryOf(src)) ?? []
            var seen = Set<String>()
            let fresh = all.filter { seen.insert($0.uri.isEmpty ? $0.id : $0.uri).inserted }
            let likedId = fresh.first { $0.kind == .likedSongs }?.id
            var liked: [SpotifyTrack] = []
            if let lid = likedId {
                var offset = 0
                while offset < 3000 {
                    guard let page = try? await api.playlistTracks(lid, limit: 100, offset: offset) else { break }
                    liked += page.items.map { $0.track }.filter { !$0.isLocal && !$0.id.isEmpty }
                    offset += 100
                    if page.items.isEmpty || offset >= page.total { break }
                }
            }
            var have: [String] = []
            if let m = m {
                have = ((try? await api.libraryOf(m)) ?? []).filter { $0.kind == .album }.map { e in
                    let k = AlbumMatch.key(e.name, e.creator)
                    return k.artist + "|" + k.title
                }
            }
            var ids = Set<String>()
            let lists = TransferLists(at: Date(), entries: fresh, tracks: liked.filter { ids.insert($0.id).inserted }, mainAlbums: have)
            await MainActor.run {
                if !fresh.isEmpty || !liked.isEmpty {
                    transferMemory[key] = lists
                    try? JSONEncoder().encode(lists).write(to: Self.file(key), options: .atomic)
                    show(lists)
                }
                loading = false
            }
        }
    }
}

/// Заметная кнопка на iOS 14 (`.borderedProminent` есть только с iOS 15).
struct BorderedProminentCompat: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
