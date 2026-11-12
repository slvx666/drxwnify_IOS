import SwiftUI

/// «Статистика» (HOME-100…104): сколько слушал, топ исполнителей, треков и альбомов за выбранный срок.
struct StatsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var range = 1
    @State private var stats = LibraryStore.Stats()
    @State private var showWrapped = false

    private static let ranges: [(String, Double)] = [("ios_stats_week", 7), ("ios_stats_month", 30), ("ios_stats_year", 365), ("all_time", 0)]

    var body: some View {
        List {
            Picker("", selection: $range) {
                ForEach(Self.ranges.indices, id: \.self) { i in Text(L(Self.ranges[i].0)).tag(i) }
            }
            .pickerStyle(SegmentedPickerStyle())
            .listRowBackground(Color.clear)

            HStack(spacing: 12) {
                tile("\(stats.totalMs / 60_000)", L("ios_stats_minutes"))
                tile("\(stats.plays)", L("ios_stats_plays"))
                tile("\(stats.artists.count)", L("artists"))
            }
            .listRowBackground(Color.clear)

            Button(action: { showWrapped = true }) {
                Label("Wrapped " + String(Calendar.current.component(.year, from: Date())), systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(Color(.systemBackground))
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            .listRowBackground(Color.clear)

            if !stats.artists.isEmpty {
                Section(header: Text(L("artists"))) {
                    ForEach(Array(stats.artists.prefix(10).enumerated()), id: \.offset) { i, a in
                        row(i + 1, a.image, a.name, minutes(a.ms), circle: true, link: a.id.map { AppLinks.Target(kind: .artist, id: $0, title: a.name, by: nil) })
                    }
                }
            }
            if !stats.tracks.isEmpty {
                Section(header: Text(L("songs"))) {
                    let list = stats.tracks.prefix(20).map { $0.track }
                    ForEach(Array(stats.tracks.prefix(20).enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t.track, context: Array(list), index: i, queueTitle: L("stats"),
                                 subtitle: "\(t.track.artistNames) • \(minutes(t.ms))")
                    }
                }
            }
            if !stats.albums.isEmpty {
                Section(header: Text(L("albums"))) {
                    ForEach(Array(stats.albums.prefix(10).enumerated()), id: \.offset) { i, a in
                        row(i + 1, a.image, a.name, "\(a.artist) • \(minutes(a.ms))", circle: false,
                            link: a.id.flatMap { id in id.isEmpty ? nil : AppLinks.Target(kind: .album, id: id, title: a.name, by: nil) })
                    }
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(L("stats"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: range) { _ in reload() }
        .sheet(isPresented: $showWrapped) {
            WrappedScreen().environmentObject(env).environmentObject(env.player)
                .modifier(ThemedRoot(theme: AppTheme.current))
        }
    }

    private func minutes(_ ms: Int64) -> String { L("wrapped_artist_listening_time", Int(ms / 60_000)) }

    private func reload() {
        let days = Self.ranges[range].1
        let since: Int64 = days > 0 ? Int64((Date().timeIntervalSince1970 - days * 86_400) * 1000) : 0
        let lib = env.library
        DispatchQueue.global(qos: .userInitiated).async {
            let s = lib.stats(sinceMs: since)
            DispatchQueue.main.async { stats = s }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.15)))
    }

    @ViewBuilder private func row(_ n: Int, _ image: String?, _ title: String, _ subtitle: String, circle: Bool, link: AppLinks.Target?) -> some View {
        let content = HStack(spacing: 12) {
            Text("\(n)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary).frame(width: 22)
            ArtworkView(url: image, size: 46, circle: circle, placeholderSymbol: circle ? "person.fill" : "square.stack")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        if let t = link {
            NavigationLink(destination: LinkTargetScreen(target: t)) { content }.themedRow()
        } else {
            content.themedRow()
        }
    }
}

/// Wrapped — итоги года страницами (как `ui/screens/wrapped`): время, главный исполнитель, топ-5, трек, альбом, плейлист итогов.
struct WrappedScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentation
    @State private var stats = LibraryStore.Stats()
    @State private var page = 0
    @State private var saved = false

    private var year: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color.accentColor.opacity(0.55), Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            TabView(selection: $page) {
                intro.tag(0)
                card(L("wrapped_top_artist_title"), stats.artists.first.map { ($0.image, $0.name, L("wrapped_top_artist_listening_time", Int($0.ms / 60_000))) }, circle: true).tag(1)
                list(L("wrapped_top_5_artists_title"), stats.artists.prefix(5).map { ($0.name, Int($0.ms / 60_000)) }).tag(2)
                card(L("wrapped_top_song_title"), stats.tracks.first.map { ($0.track.artworkUrl, "\($0.track.title)\n\($0.track.artistNames)", L("wrapped_top_song_listening_time", Int($0.ms / 60_000))) }, circle: false).tag(3)
                list(L("wrapped_top_5_songs_title"), stats.tracks.prefix(5).map { ("\($0.track.title) — \($0.track.artistNames)", Int($0.ms / 60_000)) }).tag(4)
                card(L("wrapped_top_album_title"), stats.albums.first.map { ($0.image, "\($0.name)\n\($0.artist)", L("wrapped_album_listening_time", Int($0.ms / 60_000))) }, circle: false).tag(5)
                ending.tag(6)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            Button(action: { presentation.wrappedValue.dismiss() }) {
                Image(systemName: "xmark").font(.headline).padding(12).background(Circle().fill(Color.black.opacity(0.3)))
            }
            .foregroundColor(.white)
            .padding()
        }
        .onAppear {
            let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
            let lib = env.library
            let since = Int64(start.timeIntervalSince1970 * 1000)
            DispatchQueue.global(qos: .userInitiated).async {
                let s = lib.stats(sinceMs: since, limit: 50)
                DispatchQueue.main.async { stats = s }
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Text(L("wrapped_intro_title")).font(.system(size: 44, weight: .black))
            Text(L("wrapped_intro_subtitle")).multilineTextAlignment(.center).foregroundColor(.secondary)
            Text(L("ios_wrapped_minutes", Int(stats.totalMs / 60_000))).font(.title2.weight(.bold)).multilineTextAlignment(.center).padding(.top, 20)
            Button(L("wrapped_intro_button")) { withAnimation { page = 1 } }
                .font(.headline).padding(.horizontal, 30).padding(.vertical, 12)
                .background(Capsule().fill(Color.accentColor)).foregroundColor(Color(.systemBackground))
        }
        .padding(30)
    }

    @ViewBuilder private func card(_ title: String, _ item: (String?, String, String)?, circle: Bool) -> some View {
        VStack(spacing: 18) {
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let it = item {
                ArtworkView(url: it.0, size: UIMetrics.width * 0.6, cornerRadius: 14, circle: circle)
                Text(it.1).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(it.2).foregroundColor(.secondary)
            } else {
                Text(L("wrapped_no_data")).foregroundColor(.secondary)
            }
        }
        .padding(30)
    }

    private func list(_ title: String, _ items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.bold))
            if items.isEmpty { Text(L("wrapped_no_data")).foregroundColor(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").font(.title.weight(.black)).foregroundColor(.accentColor).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.0).font(.headline).lineLimit(2)
                        Text(L("wrapped_artist_listening_time", it.1)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ending: some View {
        VStack(spacing: 18) {
            Text(L("wrapped_end_thanks")).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Button(action: savePlaylist) {
                Text(L(saved ? "wrapped_end_playlist_saved" : "wrapped_end_create_playlist"))
                    .font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Capsule().fill(Color.accentColor)).foregroundColor(Color(.systemBackground))
            }
            .disabled(saved || stats.tracks.isEmpty)
        }
        .padding(30)
    }

    private func savePlaylist() {
        let id = env.library.createPlaylist(name: L("wrapped_playlist_title", String(year)))
        env.library.add(stats.tracks.map { $0.track }, to: id)
        saved = true
    }
}
