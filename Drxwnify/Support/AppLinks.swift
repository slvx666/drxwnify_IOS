import Foundation

/// Ссылки приложения (CRITICAL §4.4) — перенос `utils/AppLinks.kt`.
enum AppLinks {
    static let site = "https://drxwnify.pages.dev"
    static let youtubePrefix = "yt:"

    enum Kind: String, CaseIterable {
        case album, playlist, track, artist
    }

    struct Target: Identifiable, Equatable {
        var kind: Kind
        var id: String
        var title: String?
        var by: String?
    }

    /// Как `android.net.Uri.encode`: без изменений остаются буквы, цифры и `_-!.~'()*`.
    private static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "_-!.~'()*")
        return set
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func link(_ kind: Kind, id: String, title: String? = nil, by: String? = nil) -> String {
        var query: [String] = []
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty { query.append("n=" + encode(String(t.prefix(80)))) }
        if let b = by, !b.trimmingCharacters(in: .whitespaces).isEmpty { query.append("by=" + encode(String(b.prefix(60)))) }
        return "\(site)/\(kind.rawValue)/" + encode(id) + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    /// Текст для «Поделиться»: «Исполнитель — Название» и ссылка.
    static func shareText(_ kind: Kind, id: String, title: String?, by: String?) -> String {
        var lines: [String] = []
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            if let b = by, !b.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("\(b) — \(t)") } else { lines.append(t) }
        }
        lines.append(link(kind, id: id, title: title, by: by))
        return lines.joined(separator: "\n")
    }

    /// Ссылка на трек по его id в плеере: трек каталога (`mfb:<id>`) или видео YouTube.
    static func trackLink(mediaId: String, title: String?, by: String?) -> String? {
        if let catalogId = FallbackIds.catalogId(of: mediaId) { return shareText(.track, id: catalogId, title: title, by: by) }
        if mediaId.hasPrefix("local:") { return nil }
        return shareText(.track, id: youtubePrefix + mediaId, title: title, by: by)
    }

    static func parse(_ url: URL) -> Target? {
        let segments = url.pathComponents.filter { $0 != "/" }
        let host = url.host?.lowercased()
        var kindName: String?
        var id: String?
        if (url.scheme == "https" || url.scheme == "http") && host == "drxwnify.pages.dev" {
            kindName = segments.first
            id = segments.count > 1 ? segments[1] : nil
        } else if url.scheme == "drxwnify" {
            kindName = url.host
            id = segments.first
        } else if host == "open.spotify.com" {
            // open.spotify.com/intl-de/album/<id>
            let rest = Array(segments.drop { $0.hasPrefix("intl-") })
            kindName = rest.first
            id = rest.count > 1 ? rest[1] : nil
        } else if let h = host, h.hasPrefix("music.yandex.") {
            // music.yandex.ru/album/1/track/2, /album/1, /artist/3, /users/<login>/playlists/<kind>
            if let t = segments.firstIndex(of: "track"), t + 1 < segments.count {
                return Target(kind: .track, id: YandexIds.make(segments[t + 1]), title: nil, by: nil)
            }
            if segments.count >= 2, segments[0] == "album" { return Target(kind: .album, id: YandexIds.make(segments[1]), title: nil, by: nil) }
            if segments.count >= 2, segments[0] == "artist" { return Target(kind: .artist, id: YandexIds.make(segments[1]), title: nil, by: nil) }
            if segments.count >= 4, segments[0] == "users", segments[2] == "playlists" {
                return Target(kind: .playlist, id: YandexIds.playlist(owner: segments[1], kind: segments[3]), title: nil, by: nil)
            }
            return nil
        } else {
            return nil
        }
        guard let k = kindName.flatMap(Kind.init(rawValue:)), let i = id, !i.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Target(kind: k, id: i, title: items.first { $0.name == "n" }?.value, by: items.first { $0.name == "by" }?.value)
    }
}
