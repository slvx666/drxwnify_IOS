import Foundation

/// Трек в очереди плеера — аналог `MediaMetadata` на Android. Не зависит от каталога, из которого пришёл.
struct Track: Codable, Hashable, Identifiable {
    struct Artist: Codable, Hashable {
        var id: String?
        var name: String
    }

    /// Идентификатор в БД и очереди: для трека каталога — `mfb:<id>`, как на Android.
    var id: String
    /// Идентификатор в каталоге (Spotify), если есть.
    var catalogId: String?
    var title: String
    var artists: [Artist]
    var albumId: String?
    var albumName: String?
    var durationMs: Int
    var artworkUrl: String?
    var explicit = false
    var isrc: String?

    var artistNames: String { artists.map { $0.name }.joined(separator: ", ") }

    var audioQuery: AudioQuery {
        AudioQuery(catalogId: catalogId, title: title, artists: artists.map { $0.name }.filter { !$0.isEmpty },
                   album: albumName, durationMs: durationMs, isrc: isrc)
    }
}

extension Track {
    init(_ t: SpotifyTrack, album: SpotifySimpleAlbum? = nil) {
        let al = t.album ?? album
        self.init(id: FallbackIds.of(t.id), catalogId: t.id.isEmpty ? nil : t.id, title: t.name,
                  artists: t.artists.map { Artist(id: $0.id, name: $0.name) },
                  albumId: al?.id, albumName: al?.name, durationMs: t.durationMs,
                  artworkUrl: al?.images.best(minWidth: 600), explicit: t.explicit, isrc: t.isrc)
    }
}

/// Режим повтора. Числа — как `Player.REPEAT_MODE_*` на Android (настройка `repeatMode`).
enum RepeatMode: Int, Codable {
    case off = 0, one = 1, all = 2

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}
