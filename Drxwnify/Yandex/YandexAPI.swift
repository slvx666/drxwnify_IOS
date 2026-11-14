import Foundation

/// Id сущностей Яндекс Музыки внутри приложения: `ym_`-префикс, как `YandexIds` на Android
/// (id Spotify — 22 знака base62 без `_`, поэтому префикс однозначен).
enum YandexIds {
    static let prefix = "ym_"
    static let likedSongsId = "ym_liked"

    static func isYandex(_ id: String?) -> Bool { id?.hasPrefix(prefix) ?? false }
    static func raw(_ id: String) -> String { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id }
    static func make(_ raw: String) -> String { prefix + raw }
    static func playlist(owner: String, kind: String) -> String { "\(prefix)\(owner)_\(kind)" }

    /// `ym_<uid>_<kind>` → (uid, kind).
    static func parsePlaylist(_ id: String) -> (String, String)? {
        guard isYandex(id) else { return nil }
        let r = raw(id)
        guard let sep = r.lastIndex(of: "_"), sep != r.startIndex, r.index(after: sep) != r.endIndex else { return nil }
        return (String(r[..<sep]), String(r[r.index(after: sep)...]))
    }

    /// На что указывает ссылка music.yandex.* (Android 2.3.0 `YandexIds.Link`).
    enum Link: Equatable {
        case album(String)
        /// `/users/<логин или uid>/playlists/<kind>`.
        case playlist(owner: String, kind: String)
        /// Новая ссылка «Поделиться» `/playlists/<uuid>` (например `lk.1a2b…`).
        case playlistUuid(String)
    }

    private static let host = try! NSRegularExpression(pattern: #"https?://(?:www\.)?music\.yandex\.(?:ru|com|by|kz|uz)/"#, options: .caseInsensitive)

    static func isLink(_ url: String) -> Bool {
        host.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    /// Ссылка на альбом или плейлист; nil для трека, артиста и чужих сайтов.
    static func parseLink(_ url: String) -> Link? {
        guard let m = host.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), let r = Range(m.range, in: url) else { return nil }
        let path = String(url[r.upperBound...])
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let g = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return nil }
            return (1..<g.numberOfRanges).compactMap { Range(g.range(at: $0), in: path).map { String(path[$0]) } }
        }
        if let g = groups(#"^album/(\d+)"#), let id = g.first { return .album(id) }
        if let g = groups(#"^users/([^/?#]+)/playlists/(\d+)"#), g.count == 2 {
            return .playlist(owner: g[0].removingPercentEncoding ?? g[0], kind: g[1])
        }
        if let g = groups(#"^playlists/([A-Za-z0-9.\-]+)"#), let id = g.first { return .playlistUuid(id) }
        return nil
    }
}

struct YandexError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Каталог и медиатека Яндекс Музыки (INT-010, INT-011) — перенос `yandex/.../YandexMusic.kt` и `YandexParser.kt`.
/// Звук отсюда не берётся: результаты переводятся в модели Spotify с `ym_`-id, звук ищет `AudioFallbackEngine`.
final class YandexAPI {
    static let base = "https://api.music.yandex.net"
    /// Client id официального Android-приложения Яндекс Музыки (OAuth implicit grant, CRITICAL §3.2).
    static let oauthClientId = "23cabbbdc6cd418abb4b39c32c41195d"
    static let oauthURL = URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(oauthClientId)&force_confirm=yes")!

    private let settings: TypedStore
    private var uid: String?
    private var likedCache: (Date, [TrackRef])?

    init(settings: TypedStore) {
        self.settings = settings
    }

    var token: String? {
        let t = settings.get(PK.yandexAccessToken) ?? ""
        return t.isEmpty ? nil : t
    }

    var isLinked: Bool { token != nil }

    // MARK: - Сеть

    private func request(_ path: String, params: [String: String] = [:], form: [String: String]? = nil, anonymous: Bool = false) async throws -> Any {
        var comps = URLComponents(string: "\(Self.base)/\(path)")!
        if !params.isEmpty { comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: comps.url!)
        r.timeoutInterval = 20
        if let t = token {
            r.setValue("OAuth \(t)", forHTTPHeaderField: "Authorization")
        } else if !anonymous {
            throw YandexError(status: 401, message: "Not authenticated")
        }
        r.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")
        r.setValue("Yandex-Music-API", forHTTPHeaderField: "User-Agent")
        r.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let form = form {
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            r.httpBody = form.map { k, v in
                "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&").data(using: .utf8)
        }
        let resp = try await HTTP.send(r)
        let root = JSON.object(resp.data)
        if !resp.isSuccess || root == nil {
            let e = root?.obj("error")
            throw YandexError(status: resp.status, message: e?.str("message") ?? e?.str("name") ?? "HTTP \(resp.status)")
        }
        if let e = root?.obj("error") { throw YandexError(status: 400, message: e.str("message") ?? e.str("name") ?? "error") }
        guard let result = root?["result"] else { throw YandexError(status: 500, message: "Empty result") }
        return result
    }

    private func object(_ path: String, params: [String: String] = [:], anonymous: Bool = false) async throws -> JSONObject {
        guard let o = try await request(path, params: params, anonymous: anonymous) as? JSONObject else {
            throw YandexError(status: 500, message: "Invalid payload")
        }
        return o
    }

    private func array(_ path: String, params: [String: String] = [:]) async throws -> [JSONObject] {
        ((try await request(path, params: params)) as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }

    private func requireUid() async throws -> String {
        if let u = uid { return u }
        let a = try await account()
        return a.uid
    }

    // MARK: - Аккаунт

    struct Account {
        let uid: String
        let login: String?
        let displayName: String?
    }

    func account() async throws -> Account {
        let r = try await object("account/status")
        guard let a = r.obj("account"), let id = a.str("uid"), !id.isEmpty else {
            throw YandexError(status: 401, message: "Token is not bound to an account")
        }
        uid = id
        return Account(uid: id, login: a.str("login"), displayName: a.str("displayName") ?? a.str("fullName") ?? a.str("login"))
    }

    func logout() {
        uid = nil
        likedCache = nil
    }

    // MARK: - Треки и лайки

    struct TrackRef {
        let id: String
        let albumId: String?
        let timestamp: String?
        var requestId: String { albumId.map { "\(id):\($0)" } ?? id }
    }

    func tracks(_ requestIds: [String]) async throws -> [SpotifyTrack] {
        var out: [SpotifyTrack] = []
        var start = 0
        while start < requestIds.count {
            let chunk = Array(requestIds[start..<min(start + 200, requestIds.count)])
            start += 200
            let arr = (try await request("tracks", form: ["track-ids": chunk.joined(separator: ","), "with-positions": "true"], anonymous: true)) as? [Any] ?? []
            out += arr.compactMap { ($0 as? JSONObject).flatMap { Self.track($0) } }
        }
        return out
    }

    func likedTrackRefs() async throws -> [TrackRef] {
        if let c = likedCache, Date().timeIntervalSince(c.0) < 30 { return c.1 }
        let u = try await requireUid()
        let r = try await object("users/\(u)/likes/tracks", params: ["if-modified-since-revision": "0"])
        let refs = (r.obj("library")?.objects("tracks") ?? []).compactMap { o -> TrackRef? in
            guard let id = o.str("id") else { return nil }
            return TrackRef(id: id, albumId: o.str("albumId"), timestamp: o.str("timestamp"))
        }
        likedCache = (Date(), refs)
        return refs
    }

    func likedSongs(limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        let refs = try await likedTrackRefs()
        let page = Array(refs.dropFirst(offset).prefix(limit))
        let byId = Dictionary(try await tracks(page.map { $0.requestId }).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = page.compactMap { ref in byId[YandexIds.make(ref.id)].map { SpotifyPlaylistTrack(addedAt: ref.timestamp, track: $0, uid: nil) } }
        return SpotifyPaging(items: items, total: refs.count, limit: limit, offset: offset)
    }

    func setLiked(_ type: String, id: String, liked: Bool) async throws {
        let u = try await requireUid()
        _ = try await request("users/\(u)/likes/\(type)s/\(liked ? "add-multiple" : "remove")", form: ["\(type)-ids": YandexIds.raw(id)])
        if type == "track" { likedCache = nil }
    }

    func isTrackLiked(_ id: String) async throws -> Bool {
        let raw = YandexIds.raw(id)
        return try await likedTrackRefs().contains { $0.id == raw }
    }

    // MARK: - Альбомы, артисты, плейлисты

    func album(_ id: String) async throws -> SpotifyAlbum {
        let o = try await object("albums/\(YandexIds.raw(id))/with-tracks", anonymous: true)
        guard let a = Self.album(o) else { throw YandexError(status: 500, message: "Invalid album payload") }
        return a
    }

    private func briefInfo(_ id: String) async throws -> JSONObject {
        try await object("artists/\(YandexIds.raw(id))/brief-info", anonymous: true)
    }

    func artist(_ id: String) async throws -> SpotifyArtist {
        guard let a = try await briefInfo(id).obj("artist").flatMap(Self.fullArtist) else {
            throw YandexError(status: 500, message: "Invalid artist payload")
        }
        return a
    }

    func artistTopTracks(_ id: String) async throws -> [SpotifyTrack] {
        (try await briefInfo(id)).objects("popularTracks").compactMap { Self.track($0) }
    }

    func artistDiscography(_ id: String) async throws -> SpotifyArtistDiscography {
        let raw = YandexIds.raw(id)
        var all: [SpotifyAlbum] = []
        if let o = try? await object("artists/\(raw)/direct-albums", params: ["page": "0", "page-size": "200", "sort-by": "year"]) {
            all = o.objects("albums").compactMap(Self.album)
        }
        if all.isEmpty { all = (try await briefInfo(id)).objects("albums").compactMap(Self.album) }
        return SpotifyArtistDiscography(
            albums: all.filter { $0.albumType == "album" },
            singles: all.filter { $0.albumType == "single" || $0.albumType == "ep" },
            compilations: all.filter { $0.albumType == "compilation" },
            latest: all.first)
    }

    func similarArtists(_ id: String) async throws -> [SpotifyArtist] {
        (try await object("artists/\(YandexIds.raw(id))/similar")).objects("similarArtists").compactMap(Self.fullArtist)
    }

    func myPlaylists() async throws -> [SpotifyPlaylist] {
        let u = try await requireUid()
        return try await array("users/\(u)/playlists/list").compactMap(Self.playlist)
    }

    /// Id каталога (`ym_…`) по ссылке на альбом или плейлист (Android 2.3.0 `idOfLink`); nil — ссылка не на них.
    /// Логин в ссылке меняется на uid из ответа; ссылка `/playlists/<uuid>` один раз запрашивается, чтобы узнать владельца.
    func idOfLink(_ url: String) async throws -> String? {
        switch YandexIds.parseLink(url) {
        case .album(let raw)?:
            return YandexIds.make(raw)
        case let .playlist(owner, kind)?:
            if owner.allSatisfy(\.isNumber) { return YandexIds.playlist(owner: owner, kind: kind) }
            let o = try? await object("users/\(owner)/playlists/\(kind)", anonymous: true)
            return o.flatMap(Self.playlist)?.id ?? YandexIds.playlist(owner: owner, kind: kind)
        case .playlistUuid(let uuid)?:
            let o = try await object("playlist/\(uuid)", anonymous: true)
            guard let p = Self.playlist(o.obj("playlist") ?? o) else { throw YandexError(status: 500, message: "Invalid playlist payload") }
            return p.id
        case nil:
            return nil
        }
    }

    func playlist(_ id: String) async throws -> SpotifyPlaylist {
        guard let (owner, kind) = YandexIds.parsePlaylist(id) else { throw YandexError(status: 400, message: "Bad playlist id") }
        guard let p = Self.playlist(try await object("users/\(owner)/playlists/\(kind)", anonymous: true)) else {
            throw YandexError(status: 500, message: "Invalid playlist payload")
        }
        return p
    }

    func playlistTracks(_ id: String, limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        guard let (owner, kind) = YandexIds.parsePlaylist(id) else { throw YandexError(status: 400, message: "Bad playlist id") }
        let o = try await object("users/\(owner)/playlists/\(kind)", params: ["rich-tracks": "true"], anonymous: true)
        let refs = o.objects("tracks")
        let page = Array(refs.dropFirst(offset).prefix(limit))
        let missing = page.filter { $0.obj("track") == nil }.compactMap { ref -> String? in
            guard let id = ref.str("id") else { return nil }
            return ref.str("albumId").map { "\(id):\($0)" } ?? id
        }
        var fetched: [String: SpotifyTrack] = [:]
        if !missing.isEmpty {
            for t in try await tracks(missing) { fetched[t.id] = t }
        }
        let items = page.compactMap { ref -> SpotifyPlaylistTrack? in
            let t = ref.obj("track").flatMap { Self.track($0) } ?? ref.str("id").flatMap { fetched[YandexIds.make($0)] }
            return t.map { SpotifyPlaylistTrack(addedAt: ref.str("timestamp"), track: $0, uid: nil) }
        }
        return SpotifyPaging(items: items, total: refs.count, limit: limit, offset: offset)
    }

    func isAlbumLiked(_ id: String) async throws -> Bool {
        let u = try await requireUid()
        return try await array("users/\(u)/likes/albums").contains { o in
            let a = o.obj("album") ?? o
            return YandexIds.make(a.str("id") ?? "") == id || YandexIds.make(o.str("id") ?? "") == id
        }
    }

    func isArtistLiked(_ id: String) async throws -> Bool {
        let u = try await requireUid()
        return try await array("users/\(u)/likes/artists").contains { o in
            let a = o.obj("artist") ?? o
            return YandexIds.make(a.str("id") ?? "") == id
        }
    }

    /// Медиатека в виде строк Spotify: «Мне нравится» первым, затем плейлисты, альбомы, артисты.
    func library() async throws -> [SpotifyLibraryEntry] {
        let u = try await requireUid()
        async let likes = try? likedTrackRefs()
        async let playlists = try? myPlaylists()
        async let albums = try? array("users/\(u)/likes/albums", params: ["rich": "true"])
        async let artists = try? array("users/\(u)/likes/artists", params: ["with-timestamps": "true"])
        var out: [SpotifyLibraryEntry] = []
        if let refs = await likes {
            out.append(SpotifyLibraryEntry(kind: .likedSongs, id: YandexIds.likedSongsId, uri: "yandexmusic:collection:tracks",
                                           name: L("liked_songs"), pinned: true, totalCount: refs.count))
        }
        // Плейлист «Мне нравится» (kind 3) дублирует лайки.
        for p in (await playlists ?? []) where YandexIds.parsePlaylist(p.id)?.1 != "3" {
            out.append(SpotifyLibraryEntry(kind: .playlist, id: p.id, uri: p.uri ?? p.id, name: p.name,
                                           creator: p.owner?.displayName, imageUrl: p.images.dropFirst().first?.url ?? p.images.first?.url,
                                           totalCount: p.totalTracks))
        }
        for o in (await albums ?? []) {
            let ao = o.obj("album") ?? o
            guard let a = Self.simpleAlbum(ao) else { continue }
            out.append(SpotifyLibraryEntry(kind: .album, id: a.id, uri: a.uri ?? a.id, name: a.name,
                                           creator: a.artists.map { $0.name }.joined(separator: ", "),
                                           imageUrl: a.images.dropFirst().first?.url ?? a.images.first?.url,
                                           albumType: a.albumType, addedAt: o.str("timestamp"), totalCount: ao.int("trackCount") ?? 0,
                                           year: a.releaseDate.flatMap { Int($0.prefix(4)) }))
        }
        for o in (await artists ?? []) {
            guard let a = Self.fullArtist(o.obj("artist") ?? o) else { continue }
            out.append(SpotifyLibraryEntry(kind: .artist, id: a.id, uri: a.uri ?? a.id, name: a.name,
                                           imageUrl: a.images.dropFirst().first?.url ?? a.images.first?.url, addedAt: o.str("timestamp")))
        }
        return out
    }

    // MARK: - Поиск

    func search(_ query: String, limit: Int) async throws -> SpotifySearchResult {
        let o = try await object("search", params: ["text": query, "type": "all", "page": "0", "nocorrect": "false"], anonymous: true)
        func section(_ key: String) -> [JSONObject] { Array((o.obj(key)?.objects("results") ?? []).prefix(limit)) }
        var r = SpotifySearchResult()
        r.tracks = section("tracks").compactMap { Self.track($0) }
        r.tracksTotal = o.obj("tracks")?.int("total") ?? r.tracks.count
        r.albums = section("albums").compactMap(Self.album)
        r.artists = section("artists").compactMap(Self.fullArtist)
        r.playlists = section("playlists").compactMap(Self.playlist)
        return r
    }

    // MARK: - Разбор (YandexParser)

    static func coverUrl(_ uri: String?, size: Int) -> String? {
        guard let u = uri?.trimmingCharacters(in: .whitespaces), !u.isEmpty else { return nil }
        let sized = u.replacingOccurrences(of: "%%", with: "\(size)x\(size)")
        return sized.hasPrefix("http") ? sized : "https://" + sized
    }

    static func coverImages(_ uri: String?) -> [SpotifyImage] {
        guard uri != nil else { return [] }
        return [1000, 400, 200].compactMap { s in coverUrl(uri, size: s).map { SpotifyImage(url: $0, height: s, width: s) } }
    }

    static func albumType(_ type: String?, trackCount: Int?) -> String {
        switch type?.lowercased() {
        case "single": return (trackCount ?? 1) > 3 ? "ep" : "single"
        case "compilation": return "compilation"
        default: return "album"
        }
    }

    static func artist(_ o: JSONObject) -> SpotifySimpleArtist? {
        guard let id = o.str("id") else { return nil }
        return SpotifySimpleArtist(id: YandexIds.make(id), name: o.str("name") ?? "", uri: "yandexmusic:artist:\(id)")
    }

    static func fullArtist(_ o: JSONObject) -> SpotifyArtist? {
        guard let id = o.str("id") else { return nil }
        let cover = o.obj("cover").flatMap { $0.str("uri") ?? $0.str("itemsUri") } ?? o.str("ogImage")
        return SpotifyArtist(id: YandexIds.make(id), name: o.str("name") ?? "", images: coverImages(cover), uri: "yandexmusic:artist:\(id)")
    }

    static func simpleAlbum(_ o: JSONObject) -> SpotifySimpleAlbum? {
        guard let id = o.str("id") else { return nil }
        let count = o.int("trackCount")
        return SpotifySimpleAlbum(id: YandexIds.make(id), name: o.str("title") ?? "",
                                  images: coverImages(o.str("coverUri") ?? o.str("ogImage")),
                                  releaseDate: o.str("releaseDate").map { String($0.prefix(10)) } ?? o.int("year").map(String.init),
                                  albumType: albumType(o.str("type"), trackCount: count),
                                  artists: o.objects("artists").compactMap(artist), uri: "yandexmusic:album:\(id)")
    }

    static func track(_ o: JSONObject, fallbackAlbum: SpotifySimpleAlbum? = nil) -> SpotifyTrack? {
        guard let id = o.str("id") ?? o.str("realId") else { return nil }
        let title = o.str("title") ?? ""
        var name = title
        if let v = o.str("version"), !v.isEmpty, !title.localizedCaseInsensitiveContains(v) { name = "\(title) (\(v))" }
        let albumObj = o.objects("albums").first
        var album = albumObj.flatMap(simpleAlbum) ?? fallbackAlbum
        if album != nil, album!.images.isEmpty { album!.images = coverImages(o.str("coverUri")) }
        var t = SpotifyTrack()
        t.id = YandexIds.make(id)
        t.name = name
        t.artists = o.objects("artists").compactMap(artist)
        t.album = album
        t.durationMs = o.int("durationMs") ?? 0
        t.explicit = (o.str("contentWarning") ?? "").lowercased() == "explicit"
        t.trackNumber = albumObj?.obj("trackPosition")?.int("index")
        t.uri = "yandexmusic:track:\(id)"
        return t
    }

    static func album(_ o: JSONObject) -> SpotifyAlbum? {
        guard let s = simpleAlbum(o) else { return nil }
        var tracks: [SpotifyTrack] = []
        for vol in o.arr("volumes") ?? [] {
            for case let t as JSONObject in (vol as? [Any]) ?? [] {
                if var tr = track(t, fallbackAlbum: s) {
                    tr.album = s
                    if tr.trackNumber == nil { tr.trackNumber = tracks.count + 1 }
                    tracks.append(tr)
                }
            }
        }
        var a = SpotifyAlbum()
        a.id = s.id
        a.name = s.name
        a.albumType = s.albumType
        a.artists = s.artists
        a.images = s.images
        a.releaseDate = s.releaseDate
        a.totalTracks = o.int("trackCount") ?? tracks.count
        a.tracks = tracks
        a.uri = s.uri
        return a
    }

    static func playlist(_ o: JSONObject) -> SpotifyPlaylist? {
        guard let kind = o.str("kind") else { return nil }
        let owner = o.obj("owner")
        guard let uid = o.str("uid") ?? owner?.str("uid") else { return nil }
        let cover = o.obj("cover")
        let coverUri = cover?.str("uri") ?? (cover?.arr("itemsUri")?.first as? String) ?? o.str("ogImage")
        var p = SpotifyPlaylist()
        p.id = YandexIds.playlist(owner: uid, kind: kind)
        p.name = o.str("title") ?? ""
        p.description = o.str("description")
        p.images = coverImages(coverUri)
        p.owner = SpotifyPlaylistOwner(id: uid, displayName: owner?.str("name") ?? owner?.str("login"), uri: nil)
        p.totalTracks = o.int("trackCount") ?? 0
        p.uri = "yandexmusic:playlist:\(uid):\(kind)"
        return p
    }
}
