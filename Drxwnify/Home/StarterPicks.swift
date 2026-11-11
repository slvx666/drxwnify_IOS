import Foundation

/// Главная слушателя, о котором приложение почти ничего не знает (`home/StarterPicks.kt`, HOME-003): вместо рядов
/// из пустой истории — ряды вокруг альбомов сайта обзоров drxwnslvt. Квадраты — треки этих альбомов (с кубиком),
/// ряды по жанрам и «Рядом с» — артисты сайта и близкие к ним, «Послушай сегодня» — лучшие по оценке альбомы.
enum StarterPicks {
    struct Row: Hashable { var title: String; var tracks: [SpotifyTrack] }

    struct Shown {
        var grid: [SpotifyTrack]
        var today: [SpotifyAlbum]
        var genreRows: [Row]
        var artistRows: [Row]
        var artists: [SpotifyArtist]
        var isEmpty: Bool { grid.isEmpty && today.isEmpty && genreRows.isEmpty && artistRows.isEmpty && artists.isEmpty }
    }

    private static let rowsEach = 3
    private static let tracksPerRow = 12
    private static let todayCount = 8
    private static let todayMinRating = 9.4
    private static let artistsCount = 10
    /// С этого числа прослушиваний в квадраты понемногу входят свои рекомендации.
    private static let blendFromPlays = 20
    /// После стольких прослушиваний квадраты целиком свои.
    private static let grownPlays = 75

    /// Новичок, пока не накопилось: 7 подписок и 20 лайков, или 20 подписок, или 40 лайков, или 75 прослушиваний.
    static func isNewcomer(plays: Int, liked: Int, followed: Int) -> Bool {
        let grown = (followed >= 7 && liked >= 20) || followed >= 20 || liked >= 40 || plays >= grownPlays
        return !grown
    }

    /// Доля своих рекомендаций в квадратах новичка: 0 до 20 прослушиваний, почти все к 75.
    static func personalShare(plays: Int) -> Double {
        min(1, max(0, Double(plays - blendFromPlays) / Double(grownPlays - blendFromPlays)))
    }

    static func build(api: SpotifyAPI, hideExplicit: Bool) async -> Shown? {
        let reviews = await NightReviews.shared.offline()
        Task.detached { await NightReviews.shared.refreshOnce() }
        if reviews.isEmpty { return nil }
        func ok(_ t: SpotifyTrack) -> Bool { !t.id.isEmpty && !t.isLocal && !(hideExplicit && t.explicit) }

        let albums: [(NightReviews.Review, SpotifyAlbum)] = await withTaskGroup(of: (NightReviews.Review, SpotifyAlbum)?.self) { group in
            for review in reviews {
                group.addTask {
                    guard let id = await NightReviews.shared.findAlbum(review, api: api), let album = try? await api.album(id) else { return nil }
                    return (review, album)
                }
            }
            var out: [(NightReviews.Review, SpotifyAlbum)] = []
            for await r in group { if let r = r { out.append(r) } }
            return out
        }
        if albums.isEmpty { return nil }

        func playable(_ album: SpotifyAlbum) -> [SpotifyTrack] {
            album.tracks.filter(ok).map { t in
                var t = t
                if t.album?.images.isEmpty ?? true { t.album = album.simple }
                return t
            }
        }
        // По треку с каждого альбома, не больше двух у артиста, пока не наберётся столько же, сколько у своего «Для тебя».
        let perAlbum = albums.shuffled().map { playable($0.1).shuffled() }
        var grid: [SpotifyTrack] = []
        var perArtist: [String: Int] = [:]
        for round in 0..<3 {
            for tracks in perAlbum where grid.count < ForYouRecommender.target && round < tracks.count {
                let track = tracks[round]
                let artist = track.artists.first?.name.lowercased() ?? ""
                if (perArtist[artist] ?? 0) >= 2 || grid.contains(where: { $0.id == track.id }) { continue }
                perArtist[artist, default: 0] += 1
                grid.append(track)
            }
        }
        let today = Array(albums.filter { $0.0.rating > todayMinRating }.shuffled().prefix(todayCount).map { $0.1 })

        var seenIds = Set<String>()
        let siteArtists: [(id: String, name: String, genres: [String])] = albums.compactMap { review, album in
            guard let a = album.artists.first, let id = a.id, !id.isEmpty, seenIds.insert(id).inserted else { return nil }
            return (id, a.name, review.mainGenres)
        }
        let siteIds = Set(siteArtists.map { $0.id })

        /// Ровно ряд треков, если у артистов столько есть: по одному у каждого по кругу.
        func rowOf(_ artistIds: [String]) async -> [SpotifyTrack] {
            var unique = Set<String>()
            let ids = Array(artistIds.filter { unique.insert($0).inserted }.shuffled().prefix(tracksPerRow))
            let pools: [[SpotifyTrack]] = await withTaskGroup(of: [SpotifyTrack].self) { group in
                for id in ids {
                    group.addTask { Array(((try? await api.artistTopTracks(id)) ?? []).filter(ok).prefix(8)).shuffled() }
                }
                var out: [[SpotifyTrack]] = []
                for await p in group where !p.isEmpty { out.append(p) }
                return out
            }
            var row: [SpotifyTrack] = []
            var round = 0
            while row.count < tracksPerRow && pools.contains(where: { $0.count > round }) {
                for pool in pools where row.count < tracksPerRow && round < pool.count {
                    if !row.contains(where: { $0.id == pool[round].id }) { row.append(pool[round]) }
                }
                round += 1
            }
            return row
        }
        func rowsFrom(_ rows: [Row?]) -> [Row] {
            Array(rows.compactMap { $0 }.sorted { ($0.tracks.count >= tracksPerRow ? 1 : 0) > ($1.tracks.count >= tracksPerRow ? 1 : 0) }.prefix(rowsEach))
        }

        var artistRowsRaw: [Row?] = []
        for a in siteArtists.shuffled().prefix(rowsEach + 2) {
            let near = ((try? await api.artistRelatedArtists(a.id)) ?? []).map { $0.id }.filter { !$0.isEmpty && !siteIds.contains($0) }
            let row = await rowOf(near)
            artistRowsRaw.append(row.isEmpty ? nil : Row(title: a.name, tracks: row))
        }
        // Жанры, в которых у сайта несколько альбомов: его артисты там и близкие к ним.
        var genreCount: [String: Int] = [:]
        for a in siteArtists { for g in a.genres { genreCount[g, default: 0] += 1 } }
        let genres = genreCount.filter { $0.value >= 2 }.map { $0.key }.shuffled()
        var genreRowsRaw: [Row?] = []
        for genre in genres.prefix(rowsEach + 2) {
            let ofGenre = Array(siteArtists.filter { $0.genres.contains(genre) }.map { $0.id }.shuffled().prefix(4))
            var near: [String] = []
            for id in ofGenre { near += ((try? await api.artistRelatedArtists(id)) ?? []).prefix(6).map { $0.id } }
            let row = await rowOf(ofGenre + near.filter { !$0.isEmpty })
            genreRowsRaw.append(row.isEmpty ? nil : Row(title: genre.capitalized, tracks: row))
        }
        var artists: [SpotifyArtist] = []
        for a in siteArtists.shuffled().prefix(artistsCount + 5) where artists.count < artistsCount {
            if let p = try? await api.artist(a.id) { artists.append(p) }
        }
        let shown = Shown(grid: grid, today: today, genreRows: rowsFrom(genreRowsRaw), artistRows: rowsFrom(artistRowsRaw), artists: artists)
        return shown.isEmpty ? nil : shown
    }
}
