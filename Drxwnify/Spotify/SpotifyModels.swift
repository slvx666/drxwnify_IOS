import Foundation

// Модели каталога Spotify. Поля и имена — как в android/spotify/.../models/*.kt.

struct SpotifyImage: Codable, Hashable {
    var url: String = ""
    var height: Int?
    var width: Int?
}

struct SpotifySimpleArtist: Codable, Hashable {
    var id: String?
    var name: String = ""
    var uri: String?
}

struct SpotifySimpleAlbum: Codable, Hashable {
    var id: String = ""
    var name: String = ""
    var images: [SpotifyImage] = []
    var releaseDate: String?
    var albumType: String?
    var artists: [SpotifySimpleArtist] = []
    var uri: String?
}

struct SpotifyTrack: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String = ""
    var artists: [SpotifySimpleArtist] = []
    var album: SpotifySimpleAlbum?
    var durationMs: Int = 0
    var explicit: Bool = false
    var isLocal: Bool = false
    var trackNumber: Int?
    var uri: String?
    var popularity: Int?
    var isrc: String?
    /// Число прослушиваний в Spotify, если ответ его содержал.
    var playCount: Int?

    var artistNames: String { artists.map { $0.name }.joined(separator: ", ") }
}

struct SpotifyAlbum: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String = ""
    var albumType: String?
    var artists: [SpotifySimpleArtist] = []
    var images: [SpotifyImage] = []
    var releaseDate: String?
    var totalTracks: Int = 0
    var tracks: [SpotifyTrack] = []
    var uri: String?

    var artistNames: String { artists.map { $0.name }.joined(separator: ", ") }
    var year: String? { releaseDate.map { String($0.prefix(4)) } }

    /// «Сингл», «Альбом», «Мини-альбом», «Сборник» (как `lib_type_*` на Android).
    var typeTitle: String? {
        switch albumType {
        case "single": return L("lib_type_single")
        case "ep": return L("lib_type_ep")
        case "compilation": return L("lib_type_compilation")
        case "album": return L("lib_type_album")
        default: return nil
        }
    }

    /// Полная дата релиза «11 нояб. 2026 г.» (LIB-029); если известен только год — год.
    var fullDate: String? {
        guard let raw = releaseDate, raw.count >= 10 else { return year }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(raw.prefix(10))) else { return year }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }

    var simple: SpotifySimpleAlbum {
        SpotifySimpleAlbum(id: id, name: name, images: images, releaseDate: releaseDate, albumType: albumType, artists: artists, uri: uri)
    }
}

struct SpotifyArtist: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String = ""
    var images: [SpotifyImage] = []
    var uri: String?
    var monthlyListeners: Int?
}

struct SpotifyPlaylistOwner: Codable, Hashable {
    var id: String = ""
    var displayName: String?
    var uri: String?
}

struct SpotifyPlaylist: Codable, Hashable, Identifiable {
    var id: String = ""
    var name: String = ""
    var description: String?
    var images: [SpotifyImage] = []
    var owner: SpotifyPlaylistOwner?
    var totalTracks: Int = 0
    var uri: String?
    var collaborative: Bool = false
}

/// Трек плейлиста. `uid` нужен GQL-мутациям (удаление, перестановка).
struct SpotifyPlaylistTrack: Codable, Hashable {
    var addedAt: String?
    var track: SpotifyTrack
    var uid: String?
}

/// Строка «Моей медиатеки» Spotify в порядке самого Spotify (закреплённые, затем недавние).
struct SpotifyLibraryEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case playlist = "PLAYLIST", album = "ALBUM", artist = "ARTIST", likedSongs = "LIKED_SONGS", folder = "FOLDER" }

    var kind: Kind
    var id: String
    var uri: String
    var name: String
    /// Владелец плейлиста или исполнители альбома.
    var creator: String?
    var imageUrl: String?
    var albumType: String?
    var pinned: Bool = false
    var addedAt: String?
    var totalCount: Int = 0
}

struct SpotifyUser: Codable, Hashable {
    var id: String
    var displayName: String?
    var images: [SpotifyImage] = []
}

struct SpotifyPaging<T> {
    var items: [T] = []
    var total: Int = 0
    var limit: Int = 20
    var offset: Int = 0
}

struct SpotifyHomeItem: Hashable, Identifiable {
    enum Kind { case playlist, album, artist }

    var kind: Kind
    var id: String
    var uri: String
    var name: String
    var subtitle: String?
    var imageUrl: String?
    /// Плейлист: владелец («Spotify» у миксов и редакторских) и «для кого» у личных миксов.
    var owner: String?
    var madeFor: String?
}

struct SpotifyHomeSection: Identifiable {
    var uri: String
    var title: String?
    var typename: String
    var items: [SpotifyHomeItem]

    var id: String { uri + (title ?? "") }
}

struct SpotifyHomeFeed {
    var greeting: String?
    var sections: [SpotifyHomeSection]
}

struct SpotifySearchResult {
    var tracks: [SpotifyTrack] = []
    var tracksTotal = 0
    var albums: [SpotifyAlbum] = []
    var artists: [SpotifyArtist] = []
    var playlists: [SpotifyPlaylist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

struct SpotifyArtistDiscography {
    var albums: [SpotifyAlbum] = []
    var singles: [SpotifyAlbum] = []
    var compilations: [SpotifyAlbum] = []
    var latest: SpotifyAlbum?
}

struct SpotifyInternalToken {
    let accessToken: String
    let accessTokenExpirationTimestampMs: Int64
    let isAnonymous: Bool
}

struct SpotifyError: Error, LocalizedError {
    let statusCode: Int
    let message: String
    var retryAfterSec: Int = 0

    var errorDescription: String? { message }
}

extension Array where Element == SpotifyImage {
    /// Самая маленькая картинка не уже `minWidth` (для списков), иначе самая большая.
    func best(minWidth: Int) -> String? {
        let known = filter { $0.width != nil }.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        if let fit = known.first(where: { ($0.width ?? 0) >= minWidth }) { return fit.url }
        return known.last?.url ?? first?.url
    }
}
