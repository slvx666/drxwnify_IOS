import SwiftUI

/// Открывает историю поверх всего.
struct StoryPresenter: ViewModifier {
    @Binding var story: Story?
    @EnvironmentObject private var env: AppEnvironment

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { story != nil }, set: { if !$0 { story = nil } })) {
            if let s = story {
                StoryView(story: s, engine: env.audio) { story = nil }.environmentObject(env)
            }
        }
    }
}

extension View {
    func storyCover(_ story: Binding<Story?>) -> some View { modifier(StoryPresenter(story: story)) }
}

/// Статистика сервиса (Android 2.3.0 `ServiceStatsScreen`, маршрут `account_stats/<SOURCE>`):
/// Spotify — вкладки «4 недели / 6 месяцев / Всё время», топ исполнителей и треков; Яндекс — лайки по месяцам и исполнители.
struct ServiceStatsScreen: View {
    let source: CatalogSource
    @EnvironmentObject private var env: AppEnvironment
    @State private var range = SpotifyAPI.TopRange.SHORT_TERM
    @State private var tops: ServiceStats.SpotifyTops?
    @State private var yandex: ServiceStats.YandexStats?
    @State private var loading = false
    @State private var error: String?
    @State private var story: Story?

    var body: some View {
        List {
            if source == .SPOTIFY {
                Picker("", selection: $range) {
                    ForEach(SpotifyAPI.TopRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .listRowBackground(Color.clear)
            }
            if loading { LoadStatusRow(isLoading: true, error: nil, retry: {}) }
            if let e = error { LoadStatusRow(isLoading: false, error: e, retry: { load(force: true) }) }
            if source == .SPOTIFY, let t = tops { spotify(t) }
            if source == .YANDEX, let y = yandex { yandexView(y) }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(source.title + " · " + L("service_stats_title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
        .onChange(of: range) { _ in load(force: false) }
        .storyCover($story)
    }

    private func watchButton(_ make: @escaping () -> Story?) -> some View {
        Button(action: { story = make() }) {
            Label(L("story_watch"), systemImage: "play.circle.fill").font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundColor(Color(.systemBackground))
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private func spotify(_ t: ServiceStats.SpotifyTops) -> some View {
        watchButton { StoryBuilder.spotify(t, range: range) }
        Section(header: Text(L("stats_top_artists"))) {
            ForEach(Array(t.artists.prefix(20).enumerated()), id: \.offset) { i, a in
                NavigationLink(destination: SpotifyArtistScreen(artistId: a.id, name: a.name)) {
                    rank(i + 1, a.image, a.name, nil, circle: true)
                }
            }
        }
        Section(header: Text(L("stats_top_tracks"))) {
            let list = t.tracks.prefix(50).map { Track($0) }
            ForEach(Array(list.enumerated()), id: \.offset) { i, tr in
                TrackRow(track: tr, context: Array(list), index: i, queueTitle: L("stats_top_tracks"))
            }
        }
    }

    @ViewBuilder private func yandexView(_ y: ServiceStats.YandexStats) -> some View {
        Section {
            Text(L("stats_yandex_total", y.total)).font(.headline)
        }
        watchButton { StoryBuilder.yandex(y) }
        Section(header: Text(L("stats_likes_by_month"))) {
            let top = max(1, y.months.map { $0.count }.max() ?? 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(y.months, id: \.self) { m in
                    VStack(spacing: 3) {
                        Text("\(m.count)").font(.system(size: 9)).foregroundColor(.secondary)
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                            .frame(height: max(2, CGFloat(m.count) / CGFloat(top) * 120))
                        Text(ServiceStats.monthLabel(m.key)).font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
        }
        Section(header: Text(L("stats_liked_artists"))) {
            ForEach(Array(y.artists.prefix(20).enumerated()), id: \.offset) { i, a in
                NavigationLink(destination: SpotifyArtistScreen(artistId: a.id, name: a.name)) {
                    rank(i + 1, a.image, a.name, L("story_in_likes", a.count), circle: true)
                }
            }
        }
    }

    private func rank(_ n: Int, _ image: String?, _ title: String, _ sub: String?, circle: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundColor(.secondary).frame(width: 24)
            ArtworkView(url: image, size: 44, circle: circle, placeholderSymbol: circle ? "person.fill" : "music.note")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let s = sub { Text(s).font(.caption).foregroundColor(.secondary) }
            }
        }
    }

    private func load(force: Bool) {
        error = nil
        let api = env.spotify, r = range
        if source == .SPOTIFY {
            tops = ServiceStats.cachedSpotify(r)
            loading = tops == nil
        } else {
            yandex = ServiceStats.cachedYandex()
            loading = yandex == nil
        }
        let src = source
        Task {
            do {
                if src == .SPOTIFY {
                    let t = try await ServiceStats.spotify(r, api: api, force: force)
                    await MainActor.run { if range == r { tops = t }; loading = false }
                } else {
                    let y = try await ServiceStats.yandex(api: api, force: force)
                    await MainActor.run { yandex = y; loading = false }
                }
            } catch {
                await MainActor.run {
                    loading = false
                    if tops == nil && yandex == nil { self.error = L("stats_failed", error.localizedDescription) }
                }
            }
        }
    }
}

/// «Статистика» в Интеграциях (Android 2.3.0 `AppStatsScreen`): итоги месяца за последние 6 месяцев — каждая строка открывает
/// историю; числа приложения. Считается только по прослушиваниям в этом приложении.
struct AppStatsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var months: [(Date, Int, Int)] = AppStatsScreen.memory
    @State private var summary = LibraryStore.Summary()
    @State private var story: Story?
    @State private var opening: Date?
    private static var memory: [(Date, Int, Int)] = []

    var body: some View {
        List {
            Section(footer: Text(L("app_stats_scope"))) {
                if months.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(height: 40)
                    }
                }
                ForEach(months, id: \.0) { m in
                    Button(action: { open(m.0) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("month_review_title", StoryBuilder.monthTitle(m.0))).foregroundColor(.primary)
                                Text(L("story_listens_minutes", m.2, m.1)).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if opening == m.0 { ProgressView() } else {
                                Image(systemName: "arrow.right.circle").font(.title3).foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            Section(header: Text(L("app_stats_listening"))) {
                let s = env.library.stats(sinceMs: 0, limit: 1)
                let monthStart = Int64(StoryBuilder.monthBounds(Date()).0.timeIntervalSince1970 * 1000)
                let m = env.library.stats(sinceMs: monthStart, limit: 1)
                row(L("app_stats_minutes_month"), "\(m.totalMs / 60_000)")
                row(L("app_stats_minutes_all"), "\(s.totalMs / 60_000)")
                row(L("app_stats_listens_all"), "\(s.plays)")
                row(L("app_stats_liked"), "\(summary.liked)")
                row(L("app_stats_playlists"), "\(env.library.playlists().count)")
                row(L("app_stats_friends"), "\(env.friends.friends.count)")
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("service_stats_title"))
        .onAppear(perform: load)
        .storyCover($story)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) }
    }

    private func load() {
        summary = env.library.summary()
        let lib = env.library
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [(Date, Int, Int)] = []
            let cal = Calendar.current
            for back in 0..<6 {
                guard let d = cal.date(byAdding: .month, value: -back, to: Date()) else { continue }
                let (start, end) = StoryBuilder.monthBounds(d)
                let s = lib.stats(sinceMs: Int64(start.timeIntervalSince1970 * 1000), untilMs: Int64(end.timeIntervalSince1970 * 1000), limit: 1)
                if s.plays > 0 { out.append((start, Int(s.totalMs / 60_000), s.plays)) }
            }
            DispatchQueue.main.async {
                months = out
                AppStatsScreen.memory = out
            }
        }
    }

    private func open(_ month: Date) {
        guard opening == nil else { return }
        opening = month
        let lib = env.library
        Task {
            let s = await StoryBuilder.month(month, library: lib)
            await MainActor.run {
                opening = nil
                story = s
            }
        }
    }
}
