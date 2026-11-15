import Foundation
import GRDB

/// Музыкальный портрет профиля (Android `portrait/Portrait.kt`): неделя, месяц, год, 12 календарных месяцев и 3 жанра-тега.
/// Собирается раз в сутки из истории этого телефона и лайков, уходит друзьям полем `portrait` в том же формате, что на Android.
struct PortraitArtist: Hashable {
    var name: String
    var minutes: Int
    var likes: Int
    var cover: String?
}

struct PortraitTrack: Hashable {
    var track: FriendsHub.TrackRef
    var plays: Int
    var liked: Bool
}

struct Portrait: Hashable {
    var minutes: Int
    var tracks: Int
    var newLikes: Int
    /// Слушал мало — картина по лайкам за период.
    var byLikes: Bool
    var artists: [PortraitArtist]
    /// Жанр → процент, сильнейшие первыми; "" — всё остальное.
    var genres: [(String, Int)]
    var topTracks: [PortraitTrack]

    static func == (a: Portrait, b: Portrait) -> Bool {
        a.minutes == b.minutes && a.tracks == b.tracks && a.newLikes == b.newLikes && a.artists == b.artists
            && a.genres.map { $0.0 } == b.genres.map { $0.0 } && a.topTracks == b.topTracks
    }
    func hash(into h: inout Hasher) { h.combine(minutes); h.combine(tracks) }
}

struct ProfilePortrait: Equatable {
    var at: Int64
    var tags: [String]
    var week: Portrait?
    var month: Portrait?
    var year: Portrait?
    /// "2026-10" → месяц.
    var months: [String: Portrait]
}

enum PortraitBuilder {
    /// Как `PortraitBuilder.VERSION` на Android: другой способ подсчёта — пересобрать сразу.
    static let version = 4
    private static let repeatBonus = 2.0, likedBonus = 1.0, likeOnlyWeight = 0.5
    private static let maxGenres = 10

    private struct Play { let songId: String; let artist: String; let at: Int64; let ms: Int64; let track: FriendsHub.TrackRef }
    private struct Like { let songId: String; let artist: String; let at: Int64; let track: FriendsHub.TrackRef }

    /// Сколько надо прослушать, чтобы засчиталось (Android `Listening.neededMs`).
    static func neededMs(_ durationMs: Int64, floor: Int64 = 30_000) -> Int64 {
        if durationMs <= 0 { return max(60_000, floor) }
        if durationMs < floor { return durationMs * 9 / 10 }
        return min(max(durationMs / 2, floor), max(240_000, floor))
    }

    static func build(database: AppDatabase) async -> ProfilePortrait {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(from: cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: -12, to: now) ?? now)) ?? now
        let sinceMs = Int64(start.timeIntervalSince1970 * 1000)
        let (plays, likes): ([Play], [Like]) = (try? await database.pool.read { db -> ([Play], [Like]) in
            let artistSQL = "(SELECT a.name FROM song_artist_map m JOIN artist a ON a.id = m.artistId WHERE m.songId = s.id ORDER BY m.position LIMIT 1)"
            let allSQL = "(SELECT GROUP_CONCAT(a.name, ', ') FROM song_artist_map m JOIN artist a ON a.id = m.artistId WHERE m.songId = s.id)"
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.songId, e.timestamp, e.playTime, s.title, s.duration, s.thumbnailUrl, \(artistSQL) AS artist, \(allSQL) AS artists
                FROM event e JOIN song s ON s.id = e.songId WHERE e.timestamp >= ?
                """, arguments: [sinceMs])
            var plays: [Play] = []
            for r in rows {
                let duration = Int64((r["duration"] as Int?) ?? 0) * 1000
                let played: Int64 = r["playTime"] ?? 0
                guard played >= neededMs(duration), let artist = (r["artist"] as String?), !artist.isEmpty else { continue }
                let id: String = r["songId"]
                plays.append(Play(songId: id, artist: artist, at: r["timestamp"], ms: played,
                                  track: ref(id: id, title: r["title"] ?? "", artists: r["artists"] ?? artist, cover: r["thumbnailUrl"], duration: duration)))
            }
            let likeRows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.title, s.duration, s.thumbnailUrl, s.likedDate, \(artistSQL) AS artist, \(allSQL) AS artists
                FROM song s WHERE s.liked = 1 AND s.likedDate IS NOT NULL
                """)
            let likes: [Like] = likeRows.compactMap { r in
                guard let artist = (r["artist"] as String?), !artist.isEmpty, let at = (r["likedDate"] as Int64?) else { return nil }
                let id: String = r["id"]
                return Like(songId: id, artist: artist, at: at,
                            track: ref(id: id, title: r["title"] ?? "", artists: r["artists"] ?? artist, cover: r["thumbnailUrl"],
                                       duration: Int64((r["duration"] as Int?) ?? 0) * 1000))
            }
            return (plays, likes)
        }) ?? ([], [])

        let likedIds = Set(likes.map { $0.songId })
        var likesByArtist: [String: Int] = [:]
        for l in likes { likesByArtist[l.artist.lowercased(), default: 0] += 1 }

        // Жанры тех, кто может попасть в топ: самые слушаемые и самые лайкнутые исполнители.
        func topNames<T>(_ list: [T], _ key: (T) -> String, _ n: Int) -> [String] {
            var c: [String: Int] = [:]
            for x in list { c[key(x), default: 0] += 1 }
            return c.sorted { $0.value > $1.value }.prefix(n).map { $0.key }
        }
        var seen = Set<String>()
        for name in topNames(plays, { $0.artist }, 40) + topNames(likes, { $0.artist }, 20) where seen.insert(name.lowercased()).inserted {
            _ = await Genres.shared.of(name)
        }

        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

        func portrait(_ from: Date, _ to: Date, minHours: Double, minPlays: Int, minLikes: Int) -> Portrait? {
            let f = ms(from), t = ms(to)
            let inRange = plays.filter { $0.at >= f && $0.at < t }
            let newLikes = likes.filter { $0.at >= f && $0.at < t }
            let hours = Double(inRange.reduce(0) { $0 + $1.ms }) / 3_600_000
            let enough = hours >= minHours && inRange.count >= minPlays
            if !enough && newLikes.count < minLikes { return nil }
            var artistScore: [String: Double] = [:], artistMs: [String: Int64] = [:], artistCover: [String: String] = [:]
            var songScore: [String: Double] = [:], songChosen: [String: Int] = [:]
            var songTrack: [String: FriendsHub.TrackRef] = [:], songArtist: [String: String] = [:]
            if enough {
                for p in inRange {
                    artistScore[p.artist, default: 0] += 1
                    artistMs[p.artist, default: 0] += p.ms
                    songScore[p.songId, default: 0] += 1
                    songChosen[p.songId, default: 0] += 1
                    if songTrack[p.songId] == nil { songTrack[p.songId] = p.track }
                    songArtist[p.songId] = p.artist
                }
                for (id, n) in songChosen where n >= 3 {
                    songScore[id, default: 0] += repeatBonus
                    if let a = songArtist[id] { artistScore[a, default: 0] += repeatBonus }
                }
                for id in songScore.keys where likedIds.contains(id) {
                    songScore[id, default: 0] += likedBonus
                    if let a = songArtist[id] { artistScore[a, default: 0] += likedBonus }
                }
                for l in newLikes { artistScore[l.artist, default: 0] += likeOnlyWeight }
                for a in artistScore.keys {
                    // Обложка самого слушаемого трека — вместо фото исполнителя.
                    if let best = songScore.filter({ songArtist[$0.key] == a }).max(by: { $0.value < $1.value }), let c = songTrack[best.key]?.cover {
                        artistCover[a] = c
                    }
                }
            } else {
                for l in newLikes {
                    artistScore[l.artist, default: 0] += 1
                    if artistCover[l.artist] == nil, let c = l.track.cover { artistCover[l.artist] = c }
                }
            }
            let topArtists = artistScore.sorted { $0.value > $1.value }.prefix(5).map { name, _ in
                PortraitArtist(name: name, minutes: Int((artistMs[name] ?? 0) / 60_000), likes: likesByArtist[name.lowercased()] ?? 0, cover: artistCover[name])
            }
            let topTracks: [PortraitTrack] = enough
                ? songScore.sorted { $0.value > $1.value }.prefix(5).compactMap { id, _ in
                    songTrack[id].map { PortraitTrack(track: $0, plays: songChosen[id] ?? 0, liked: likedIds.contains(id)) }
                }
                : newLikes.sorted { $0.at > $1.at }.prefix(5).map { PortraitTrack(track: $0.track, plays: 0, liked: true) }
            return Portrait(minutes: Int(inRange.reduce(0) { $0 + $1.ms } / 60_000), tracks: Set(inRange.map { $0.songId }).count,
                            newLikes: newLikes.count, byLikes: !enough, artists: Array(topArtists),
                            genres: genreShares(artistScore), topTracks: topTracks)
        }

        let soon = now.addingTimeInterval(60)
        let week = portrait(now.addingTimeInterval(-7 * 86400), soon, minHours: 1, minPlays: 8, minLikes: 10)
        let month = portrait(now.addingTimeInterval(-30 * 86400), soon, minHours: 3, minPlays: 20, minLikes: 20)
        let year = portrait(now.addingTimeInterval(-365 * 86400), soon, minHours: 10, minPlays: 60, minLikes: 40)
        var months: [String: Portrait] = [:]
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        for back in 0..<12 {
            guard let from = cal.date(byAdding: .month, value: -back, to: thisMonth), let to = cal.date(byAdding: .month, value: 1, to: from) else { continue }
            let c = cal.dateComponents([.year, .month], from: from)
            if let p = portrait(from, to, minHours: 3, minPlays: 20, minLikes: 10) {
                months[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)] = p
            }
        }
        // Теги профиля: сильнейшие жанры последних трёх месяцев.
        var tagScore: [String: Int] = [:]
        for back in 0..<3 {
            guard let from = cal.date(byAdding: .month, value: -back, to: thisMonth) else { continue }
            let c = cal.dateComponents([.year, .month], from: from)
            for (g, pct) in months[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)]?.genres ?? [] where !g.isEmpty { tagScore[g, default: 0] += pct }
        }
        var tags = tagScore.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
        if tags.isEmpty { tags = Array(((month ?? year)?.genres ?? []).map { $0.0 }.filter { !$0.isEmpty }.prefix(3)) }
        return ProfilePortrait(at: Int64(now.timeIntervalSince1970 * 1000), tags: tags, week: week, month: month, year: year, months: months)
    }

    private static func ref(id: String, title: String, artists: String, cover: String?, duration: Int64) -> FriendsHub.TrackRef {
        FriendsHub.TrackRef(title: String(title.prefix(120)), artist: String(artists.prefix(120)),
                            catalogId: FallbackIds.catalogId(of: id), mediaId: id.hasPrefix("local:") ? nil : id,
                            cover: (cover?.hasPrefix("http") ?? false) ? cover : nil, durationMs: duration)
    }

    /// Вес исполнителя по его жанрам (главный 1, затем 0,4 и 0,2), подвиды сведены к семье; топ-10 и «остальное».
    private static func genreShares(_ artistScore: [String: Double]) -> [(String, Int)] {
        var score: [String: Double] = [:]
        for (artist, w) in artistScore.sorted(by: { $0.value > $1.value }).prefix(30) {
            var genres: [String] = []
            for g in Genres.shared.cached(artist).map(Genres.family) where !genres.contains(g) { genres.append(g) }
            genres = Array(genres.prefix(3))
            if genres.isEmpty { continue }
            let parts = Array([1.0, 0.4, 0.2].prefix(genres.count))
            let sum = parts.reduce(0, +)
            for (i, g) in genres.enumerated() { score[g, default: 0] += w * parts[i] / sum }
        }
        let total = score.values.reduce(0, +)
        guard total > 0 else { return [] }
        let sorted = score.sorted { $0.value > $1.value }
        let top = sorted.prefix(maxGenres).map { ($0.key, Int(($0.value * 100 / total).rounded())) }.filter { $0.1 > 0 }
        let rest = 100 - top.reduce(0) { $0 + $1.1 }
        return rest > 0 && sorted.count > maxGenres ? top + [("", rest)] : top
    }
}

/// Упаковка для друзей: "gz1:" + base64(gzip(JSON)), как `PortraitCodec` на Android.
enum PortraitCodec {
    private static let prefix = "gz1:"

    static func pack(_ p: ProfilePortrait) -> String {
        var o: JSONObject = ["v": 1, "at": p.at, "tags": p.tags]
        if let w = p.week { o["w"] = json(w) }
        if let m = p.month { o["m"] = json(m) }
        if let y = p.year { o["y"] = json(y) }
        o["months"] = p.months.mapValues(json)
        return prefix + Gzip.compress(Data(JSON.string(o).utf8)).base64EncodedString()
    }

    static func unpack(_ content: String) -> ProfilePortrait? {
        var text = content
        if content.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(content.dropFirst(prefix.count))), let plain = Gzip.decompress(d),
                  let s = String(data: plain, encoding: .utf8) else { return nil }
            text = s
        }
        guard let o = JSON.object(text) else { return nil }
        var months: [String: Portrait] = [:]
        if let m = o["months"] as? JSONObject { for (k, v) in m { if let p = v as? JSONObject { months[k] = portrait(p) } } }
        return ProfilePortrait(at: Int64(o.int("at") ?? 0), tags: ((o.arr("tags") as? [String]) ?? []).filter { !$0.isEmpty },
                               week: o.obj("w").map(portrait), month: o.obj("m").map(portrait), year: o.obj("y").map(portrait), months: months)
    }

    private static func json(_ p: Portrait) -> JSONObject {
        [
            "min": p.minutes, "n": p.tracks, "likes": p.newLikes, "bl": p.byLikes,
            "a": p.artists.map { [$0.name, $0.minutes, $0.likes, $0.cover ?? ""] as [Any] },
            "g": p.genres.map { [$0.0, $0.1] as [Any] },
            "t": p.topTracks.map { t in
                [t.track.title, t.track.artist, t.track.catalogId ?? "", t.track.mediaId ?? "", t.track.cover ?? "",
                 Int(t.track.durationMs / 1000), t.plays, t.liked] as [Any]
            },
        ]
    }

    private static func portrait(_ o: JSONObject) -> Portrait {
        func rows(_ k: String) -> [[Any]] { (o.arr(k) ?? []).compactMap { $0 as? [Any] } }
        func s(_ r: [Any], _ i: Int) -> String { i < r.count ? ((r[i] as? String) ?? "\(r[i])") : "" }
        func n(_ r: [Any], _ i: Int) -> Int { i < r.count ? ((r[i] as? NSNumber)?.intValue ?? Int(s(r, i)) ?? 0) : 0 }
        func b(_ r: [Any], _ i: Int) -> Bool { i < r.count ? ((r[i] as? NSNumber)?.boolValue ?? false) : false }
        return Portrait(
            minutes: o.int("min") ?? 0, tracks: o.int("n") ?? 0, newLikes: o.int("likes") ?? 0, byLikes: o.bool("bl") ?? false,
            artists: rows("a").map { PortraitArtist(name: s($0, 0), minutes: n($0, 1), likes: n($0, 2), cover: s($0, 3).isEmpty ? nil : s($0, 3)) },
            genres: rows("g").map { (s($0, 0), n($0, 1)) },
            topTracks: rows("t").map { r in
                PortraitTrack(track: FriendsHub.TrackRef(title: s(r, 0), artist: s(r, 1), catalogId: s(r, 2).isEmpty ? nil : s(r, 2),
                                                         mediaId: s(r, 3).isEmpty ? nil : s(r, 3), cover: s(r, 4).isEmpty ? nil : s(r, 4),
                                                         durationMs: Int64(n(r, 5)) * 1000),
                              plays: n(r, 6), liked: b(r, 7))
            })
    }
}
