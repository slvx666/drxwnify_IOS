import Foundation

/// Страницы итогов (Android 2.3.0, раздел 7). Итоги приложения считаются только по прослушиваниям в приложении;
/// итоги сервиса — только по тому, что отдаёт сервис (у Spotify нет личного числа прослушиваний — строки «N раз» нет).
enum StoryBuilder {
    static func monthTitle(_ start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Locale.preferredLanguages.first ?? "ru")
        f.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return f.string(from: start)
    }

    static func monthBounds(_ date: Date) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        return (start, cal.date(byAdding: .month, value: 1, to: start) ?? date)
    }

    /// Итоги месяца приложения; nil — в месяце не было прослушиваний.
    static func month(_ date: Date, library: LibraryStore) async -> Story? {
        let (start, end) = monthBounds(date)
        let from = Int64(start.timeIntervalSince1970 * 1000), to = Int64(end.timeIntervalSince1970 * 1000)
        let s = library.stats(sinceMs: from, untilMs: to, limit: 21)
        guard s.plays > 0, !s.tracks.isEmpty else { return nil }
        let artists = library.stats(sinceMs: from, untilMs: to, limit: 11).artists
        let h = library.habits(sinceMs: from, untilMs: to)
        let name = monthTitle(start)
        let minutes = Int(s.totalMs / 60_000)
        let tracks = s.tracks.map { t in
            Story.Item(title: t.0.title, subtitle: t.0.artistNames, image: t.0.artworkUrl, note: L("story_times", t.1))
        }
        let artistItems = artists.map { Story.Item(title: $0.name, image: $0.image, note: L("story_times", $0.plays), round: true) }
        let topTrack = s.tracks.first?.0
        var pages: [Story.Page] = [.hello(title: L("story_hello"), sub: L("story_hello_sub", name))]
        pages.append(.big(pre: L("story_minutes_pre", name), value: "\(minutes)", unit: L("story_minutes"),
                          extra: L("story_listens_line", s.plays) + (h.newArtists > 0 ? "\n\(h.newArtists) " + L("story_new_artists") : "")))
        if let d = h.busiestDay {
            let f = DateFormatter()
            f.locale = Locale(identifier: Locale.preferredLanguages.first ?? "ru")
            f.setLocalizedDateFormatFromTemplate("d MMMM")
            pages.append(.big(pre: L("story_day_pre"), value: f.string(from: d), unit: L("story_day_minutes", Int(h.busiestDayMs / 60_000)),
                              extra: h.favoriteHour.map { L("story_hour_line", String(format: "%02d:00", $0)) }))
        }
        if let t = s.tracks.first {
            pages.append(.one(pre1: L("story_tracks_count", s.tracks.count), pre2: L("story_tracks_tease"),
                              item: Story.Item(title: t.0.title, subtitle: t.0.artistNames, image: t.0.artworkUrl, note: L("story_played_times", t.1)),
                              track: t.0))
            pages.append(.tracks(title: L("story_top_tracks"), items: tracks, track: s.tracks.count > 1 ? s.tracks[1].0 : t.0))
        }
        if let a = artists.first {
            let artistTrack = s.tracks.first { $0.0.artists.first?.name == a.name }?.0 ?? topTrack
            pages.append(.one(pre1: L("story_artists_count", artists.count), pre2: L("story_artists_tease"),
                              item: Story.Item(title: a.name, image: a.image, note: L("story_times", a.plays), round: true), track: artistTrack))
            pages.append(.artists(title: L("story_top_artists"), items: artistItems, track: artistTrack))
        }
        // Жанры: теги Last.fm главных исполнителей (то, что уже лежит в кэше, плюс несколько запросов).
        var genreCount: [String: Int] = [:]
        for a in artists.prefix(8) {
            for g in await Genres.shared.of(a.name).prefix(3) { genreCount[g, default: 0] += a.plays }
        }
        let genres = genreCount.sorted { $0.value > $1.value }.prefix(5).map { $0.key }
        if !genres.isEmpty {
            pages.append(.genres(title: L("story_genres"), lines: genres.enumerated().map { "\($0.offset + 1). \($0.element.capitalized)" }))
        }
        pages.append(.card(title: L("story_card_title", name),
                           lines: [L("story_listens_minutes", s.plays, minutes)],
                           items: tracks))
        return Story(pages: pages, title: name)
    }

    /// Итоги Spotify за выбранный период: без минут, дней и жанров; периодом в заголовках списков.
    static func spotify(_ tops: ServiceStats.SpotifyTops, range: SpotifyAPI.TopRange) -> Story? {
        guard !tops.tracks.isEmpty || !tops.artists.isEmpty else { return nil }
        let period: String = {
            switch range {
            case .SHORT_TERM: return L("story_period_short")
            case .MID_TERM: return L("story_period_medium")
            case .LONG_TERM: return L("story_period_long")
            }
        }()
        let tracks = tops.tracks.map { Track($0) }
        let trackItems = tracks.prefix(21).map { Story.Item(title: $0.title, subtitle: $0.artistNames, image: $0.artworkUrl) }
        let artistItems = tops.artists.prefix(11).map { Story.Item(title: $0.name, image: $0.image, round: true) }
        var pages: [Story.Page] = [.hello(title: L("story_hello"), sub: L("story_service_sub", "Spotify", period))]
        if let t = tracks.first {
            pages.append(.one(pre1: L("story_service_track_pre"), pre2: period, item: trackItems[0], track: t))
            pages.append(.tracks(title: L("story_service_tracks", period), items: Array(trackItems), track: tracks.count > 1 ? tracks[1] : t))
        }
        if let a = tops.artists.first {
            let t = tracks.first { $0.artists.contains { $0.name == a.name } } ?? tracks.first
            pages.append(.one(pre1: L("story_service_artist_pre"), pre2: period, item: artistItems[0], track: t))
            pages.append(.artists(title: L("story_service_artists", period), items: Array(artistItems), track: t))
        }
        pages.append(.card(title: L("story_service_card", "Spotify", period), lines: [], items: Array(trackItems)))
        return Story(pages: pages, title: "Spotify")
    }

    /// Итоги Яндекса по лайкам: «в лайках: N».
    static func yandex(_ st: ServiceStats.YandexStats) -> Story? {
        guard st.total > 0 else { return nil }
        let period = L("story_period_likes")
        let tracks = st.tracks.map { Track($0) }
        let trackItems = tracks.prefix(21).map { Story.Item(title: $0.title, subtitle: $0.artistNames, image: $0.artworkUrl) }
        let artistItems = st.artists.prefix(11).map { Story.Item(title: $0.name, image: $0.image, note: L("story_in_likes", $0.count), round: true) }
        var pages: [Story.Page] = [.hello(title: L("story_hello"), sub: L("story_service_sub", L("yandex_music"), period))]
        let best = st.months.max { $0.count < $1.count }
        pages.append(.big(pre: L("story_likes_pre", L("yandex_music")), value: "\(st.total)", unit: L("story_likes_unit"),
                          extra: best.map { L("story_likes_month", ServiceStats.monthLabel($0.key, full: true), $0.count) }))
        if let t = tracks.first {
            pages.append(.one(pre1: L("story_service_track_pre"), pre2: period, item: trackItems[0], track: t))
            pages.append(.tracks(title: L("story_service_tracks", period), items: Array(trackItems), track: tracks.count > 1 ? tracks[1] : t))
        }
        if let a = st.artists.first {
            let t = tracks.first { $0.artists.contains { $0.name == a.name } } ?? tracks.first
            pages.append(.one(pre1: L("story_yandex_artist_pre"), pre2: period, item: artistItems[0], track: t))
            pages.append(.artists(title: L("story_service_artists", period), items: Array(artistItems), track: t))
        }
        pages.append(.card(title: L("story_service_card", L("yandex_music"), period), lines: [L("story_card_likes") + ": \(st.total)"], items: Array(trackItems)))
        return Story(pages: pages, title: L("yandex_music"))
    }
}
