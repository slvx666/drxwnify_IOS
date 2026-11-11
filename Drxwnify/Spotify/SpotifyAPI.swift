import Foundation

/// Запросы к Spotify: GQL веб-плеера (pathfinder) и Web API как запасной путь (INT-005).
/// Порт `android/spotify/.../Spotify.kt`; имена операций, переменные и разбор ответов — как там.
final class SpotifyAPI {
    private static let gqlURL = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!
    private static let restBase = "https://api.spotify.com/v1/"

    private let tokens: SpotifyTokenManager
    private let hashes: SpotifyHashes

    init(tokens: SpotifyTokenManager, hashes: SpotifyHashes) {
        self.tokens = tokens
        self.hashes = hashes
    }

    /// Яндекс Музыка: `ym_`-id идут туда (как `catalog/Catalog.kt` на Android).
    var yandex: YandexAPI?
    var settings: TypedStore?

    /// Яндекс кормит медиатеку и поиск: подключён только он или выбран основным при двух аккаунтах.
    var yandexIsSource: Bool {
        guard let y = yandex, y.isLinked else { return false }
        let spotifyLinked = !(settings?.get(PK.spotifySpDc) ?? "").isEmpty
        if !spotifyLinked { return true }
        return settings?.get(PK.primaryMetadataSource) == "YANDEX"
    }

    private static func randomUserAgent() -> String {
        let os = ["Windows NT 10.0; Win64; x64", "Macintosh; Intel Mac OS X 10_15_7", "X11; Linux x86_64"].randomElement()!
        let major = 140 - Int.random(in: 0...4)
        let patch = Int.random(in: 0...499)
        return "Mozilla/5.0 (\(os)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.\(patch).0 Safari/537.36"
    }

    /// Один User-Agent на запуск, как у `defaultRequest` на Android.
    private let userAgent = SpotifyAPI.randomUserAgent()

    private func baseHeaders(token: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "app-platform": "WebPlayer",
            "Origin": "https://open.spotify.com",
            "Referer": "https://open.spotify.com/",
            "Authorization": "Bearer \(token)",
        ]
    }

    // MARK: GraphQL

    private enum GqlResult {
        case json(JSONObject)
        case persistedQueryNotFound
    }

    func graphqlPost(_ operation: String, variables: JSONObject = [:], language: String? = nil) async throws -> JSONObject {
        guard var token = await tokens.token() else {
            throw SpotifyError(statusCode: 401, message: "Not authenticated")
        }
        guard let primary = hashes.hash(operation) else {
            throw SpotifyError(statusCode: 412, message: "No hash registered for GQL operation: \(operation)")
        }
        var candidates = [primary]
        if let previous = hashes.previousHash(operation), previous != primary { candidates.append(previous) }

        for (index, hash) in candidates.enumerated() {
            let body: JSONObject = [
                "variables": variables,
                "operationName": operation,
                "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
            ]
            let result: GqlResult
            do {
                result = try await executeGql(operation, token: token, body: body, language: language)
            } catch let error as SpotifyError where error.statusCode == 401 {
                // Токен истёк или отозван раньше срока: один свежий токен, одна повторная попытка.
                guard let fresh = await tokens.token(forceRefresh: true), fresh != token else { throw error }
                token = fresh
                result = try await executeGql(operation, token: token, body: body, language: language)
            }
            switch result {
            case .json(let json):
                return json
            case .persistedQueryNotFound:
                if index < candidates.count - 1 { continue }
                // Все известные хеши отвергнуты: подтягиваем реестр к следующему запросу.
                let hashes = self.hashes
                Task.detached { await hashes.sync() }
                throw SpotifyError(statusCode: 412, message: "PersistedQueryNotFound for \(operation) — hash may have rotated")
            }
        }
        throw SpotifyError(statusCode: 412, message: "No valid hash found for \(operation)")
    }

    private func executeGql(_ operation: String, token: String, body: JSONObject, language: String?) async throws -> GqlResult {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            var request = URLRequest(url: Self.gqlURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            for (k, v) in baseHeaders(token: token) { request.setValue(v, forHTTPHeaderField: k) }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            if let language = language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
            request.httpBody = JSON.data(body)

            let response = try await HTTP.send(request)
            if response.status == 401 {
                throw SpotifyError(statusCode: 401, message: "Token expired or invalid")
            }
            if response.status == 429 {
                let retryAfter = response.header("Retry-After").flatMap { Int($0) } ?? 2 * (attempt + 1)
                if attempt < maxRetries - 1 {
                    try await sleepSeconds(Double(retryAfter))
                    continue
                }
                throw SpotifyError(statusCode: 429, message: "Rate limited", retryAfterSec: retryAfter)
            }
            if response.status == 412 { return .persistedQueryNotFound }
            if !response.isSuccess {
                throw SpotifyError(statusCode: response.status, message: "GraphQL error \(response.status): \(response.text.prefix(300))")
            }
            guard let json = JSON.object(response.data) else {
                throw SpotifyError(statusCode: 500, message: "Invalid GraphQL response")
            }
            if let first = json.objects("errors").first {
                let message = first.str("message") ?? "Unknown GraphQL error"
                if message.range(of: "PersistedQueryNotFound", options: .caseInsensitive) != nil {
                    return .persistedQueryNotFound
                }
                throw SpotifyError(statusCode: 400, message: "GraphQL: \(message)")
            }
            return .json(json)
        }
        throw SpotifyError(statusCode: 429, message: "Rate limited after \(maxRetries) retries")
    }

    // MARK: REST (там, где нет GQL-аналога)

    func restGet(_ endpoint: String, failFastOn429: Bool = false) async throws -> Data {
        guard var token = await tokens.token() else {
            throw SpotifyError(statusCode: 401, message: "Not authenticated")
        }
        guard let url = URL(string: Self.restBase + endpoint) else {
            throw SpotifyError(statusCode: 400, message: "Bad endpoint")
        }
        var refreshedAfter401 = false
        let maxRetries = failFastOn429 ? 1 : 3
        let maxRetryDelaySec = 3
        for attempt in 0..<maxRetries {
            let response = try await HTTP.get(url, headers: baseHeaders(token: token), timeout: 30)
            if response.status == 401 {
                var fresh: String?
                if !refreshedAfter401 { fresh = await tokens.token(forceRefresh: true) }
                guard let newToken = fresh, newToken != token else {
                    throw SpotifyError(statusCode: 401, message: "Token expired or invalid")
                }
                refreshedAfter401 = true
                token = newToken
                let retried = try await HTTP.get(url, headers: baseHeaders(token: token), timeout: 30)
                if retried.isSuccess { return retried.data }
                if retried.status == 401 { throw SpotifyError(statusCode: 401, message: "Token expired or invalid") }
                throw SpotifyError(statusCode: retried.status, message: "Spotify API error \(retried.status)")
            }
            if response.status == 429 {
                let retryAfter = response.header("Retry-After").flatMap { Int($0) } ?? 2 * (attempt + 1)
                if failFastOn429 || retryAfter > maxRetryDelaySec || attempt >= maxRetries - 1 {
                    throw SpotifyError(statusCode: 429, message: "Rate limited", retryAfterSec: retryAfter)
                }
                try await sleepSeconds(Double(retryAfter))
                continue
            }
            if !response.isSuccess {
                throw SpotifyError(statusCode: response.status, message: "Spotify API error \(response.status): \(response.text.prefix(300))")
            }
            return response.data
        }
        throw SpotifyError(statusCode: 429, message: "Rate limited after \(maxRetries) retries")
    }

    // MARK: Разбор ответов GQL

    private func parseImages(_ sources: [Any]?) -> [SpotifyImage] {
        (sources ?? []).compactMap { item in
            guard let o = item as? JSONObject, let url = o.str("url") else { return nil }
            return SpotifyImage(url: url, height: o.int("height"), width: o.int("width"))
        }
    }

    private func parseSimpleArtist(_ o: JSONObject) -> SpotifySimpleArtist? {
        guard let uri = o.str("uri") else { return nil }
        return SpotifySimpleArtist(id: uri.substringAfterLast(":"), name: o.obj("profile")?.str("name") ?? "", uri: uri)
    }

    /// Общая структура трека для fetchPlaylist, fetchLibraryTracks, queryArtistOverview, getAlbum.
    private func parseTrack(_ data: JSONObject, albumOverride: SpotifySimpleAlbum? = nil, uriOverride: String? = nil) -> SpotifyTrack {
        let uri = uriOverride ?? data.str("uri") ?? data.str("_uri") ?? ""
        let artists = (data.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist)
        let album: SpotifySimpleAlbum
        if let override = albumOverride {
            album = override
        } else {
            let a = data.obj("albumOfTrack")
            let albumUri = a?.str("uri") ?? ""
            album = SpotifySimpleAlbum(
                id: albumUri.substringAfterLast(":"),
                name: a?.str("name") ?? "",
                images: parseImages(a?.obj("coverArt")?.arr("sources")),
                uri: albumUri.isEmpty ? nil : albumUri
            )
        }
        let playCount = (data.str("playcount").flatMap { Int($0) }) ?? (data.str("playCount").flatMap { Int($0) })
        var track = SpotifyTrack()
        track.id = uri.substringAfterLast(":")
        track.name = data.str("name") ?? ""
        track.artists = artists
        track.album = album
        track.durationMs = parseDurationMs(data)
        track.uri = uri.isEmpty ? nil : uri
        track.playCount = playCount
        if let rating = data.obj("contentRating")?.str("label") { track.explicit = rating == "EXPLICIT" }
        return track
    }

    private func parseDurationMs(_ data: JSONObject) -> Int {
        if let v = data.obj("duration")?.int("totalMilliseconds"), v > 0 { return v }
        if let v = data.int("durationMs"), v > 0 { return v }
        if let v = data.int("duration_ms"), v > 0 { return v }
        if let v = data.int("duration"), v > 0 { return v * 1000 }
        return 0
    }

    private func releaseDate(_ date: JSONObject?) -> String? {
        guard let date = date else { return nil }
        guard let year = date.int("year") else { return date.str("isoString").map { String($0.prefix(4)) } }
        let precision = date.str("precision")
        if precision == nil || precision == "DAY" {
            if let iso = date.str("isoString").map({ String($0.prefix(10)) }), iso.count == 10, iso.hasPrefix(String(year)) {
                return iso
            }
            if let month = date.int("month"), let day = date.int("day") {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
        }
        return String(year)
    }

    private func parseRelease(_ release: JSONObject, type: String) -> SpotifyAlbum? {
        guard let uri = release.str("uri") ?? release.str("id").map({ "spotify:album:\($0)" }) else { return nil }
        let id = uri.substringAfterLast(":")
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty, let name = release.str("name") else { return nil }
        var album = SpotifyAlbum()
        album.id = id
        album.name = name
        album.albumType = type
        album.images = parseImages(release.obj("coverArt")?.arr("sources"))
        album.releaseDate = releaseDate(release.obj("date"))
        album.totalTracks = release.obj("tracks")?.int("totalCount") ?? 0
        album.uri = uri
        return album
    }

    private func parsePlaylistImages(_ images: JSONObject?) -> [SpotifyImage] {
        (images?.objects("items") ?? []).flatMap { parseImages($0.arr("sources")) }
    }

    // MARK: Профиль

    func me() async throws -> SpotifyUser {
        do {
            let response = try await graphqlPost("profileAttributes")
            guard let profile = response.obj("data")?.obj("me")?.obj("profile") else {
                throw SpotifyError(statusCode: 500, message: "Invalid profileAttributes response")
            }
            let uri = profile.str("uri") ?? ""
            return SpotifyUser(id: uri.substringAfterLast(":"), displayName: profile.str("name"),
                               images: parseImages(profile.obj("avatar")?.arr("sources")))
        } catch {
            guard let json = JSON.object(try await restGet("me")), let id = json.str("id") else { throw error }
            return SpotifyUser(id: id, displayName: json.str("display_name"), images: parseImages(json.arr("images")))
        }
    }

    // MARK: Медиатека (libraryV3)

    /// «Моя медиатека» в порядке клиента Spotify: закреплённые, затем недавние.
    /// - Parameters:
    ///   - filter: `nil` — всё, либо `"Playlists"`, `"Albums"`, `"Artists"`.
    ///   - folderUri: содержимое папки плейлистов.
    func myLibrary(filter: String? = nil, folderUri: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> SpotifyPaging<SpotifyLibraryEntry> {
        let vars: JSONObject = [
            "filters": filter.map { [$0] } ?? [String](),
            "order": NSNull(),
            "textFilter": "",
            "features": ["LIKED_SONGS", "YOUR_EPISODES_V2", "PRERELEASES", "EVENTS"],
            "limit": limit,
            "offset": offset,
            "flatten": false,
            "expandedFolders": [String](),
            "folderUri": folderUri ?? NSNull(),
            "includeFoldersWhenFlattening": true,
        ]
        let response = try await graphqlPost("libraryV3", variables: vars)
        guard let library = response.obj("data")?.obj("me")?.obj("libraryV3") else {
            throw SpotifyError(statusCode: 500, message: "Invalid libraryV3 response")
        }
        let entries = library.objects("items").compactMap { item -> SpotifyLibraryEntry? in
            guard let wrapper = item.obj("item") else { return nil }
            let typeName = wrapper.str("__typename") ?? ""
            let data = wrapper.obj("data")
            let uri = wrapper.str("_uri") ?? data?.str("uri") ?? ""
            return parseLibraryEntry(typeName: typeName, uri: uri, data: data,
                                     pinned: item.bool("pinned") ?? false,
                                     addedAt: item.obj("addedAt")?.str("isoString"))
        }
        return SpotifyPaging(items: entries, total: library.int("totalCount") ?? 0, limit: limit, offset: offset)
    }

    private func parseLibraryEntry(typeName: String, uri: String, data: JSONObject?, pinned: Bool, addedAt: String?) -> SpotifyLibraryEntry? {
        let id = uri.substringAfterLast(":")
        func has(_ s: String) -> Bool { typeName.range(of: s, options: .caseInsensitive) != nil }

        if uri.contains(":collection") && (has("Pseudo") || uri.hasSuffix("collection")) {
            return SpotifyLibraryEntry(kind: .likedSongs, id: "liked_songs", uri: uri,
                                       name: data?.str("name") ?? "Liked Songs",
                                       pinned: pinned, addedAt: addedAt, totalCount: data?.int("count") ?? 0)
        }
        if has("Folder") {
            guard let name = data?.str("name") else { return nil }
            return SpotifyLibraryEntry(kind: .folder, id: id, uri: uri, name: name, pinned: pinned, addedAt: addedAt,
                                       totalCount: data?.int("playlistCount") ?? data?.int("totalLength") ?? 0)
        }
        if has("Playlist") {
            guard let data = data, data.str("__typename") == "Playlist" else { return nil }
            return SpotifyLibraryEntry(kind: .playlist, id: id, uri: uri, name: data.str("name") ?? "",
                                       creator: data.obj("ownerV2")?.obj("data")?.str("name"),
                                       imageUrl: parsePlaylistImages(data.obj("images")).first?.url,
                                       pinned: pinned, addedAt: addedAt)
        }
        if has("Album") {
            guard let data = data else { return nil }
            let creator = data.obj("artists")?.objects("items").compactMap { $0.obj("profile")?.str("name") }.joined(separator: ", ")
            return SpotifyLibraryEntry(kind: .album, id: id, uri: uri, name: data.str("name") ?? "",
                                       creator: creator,
                                       imageUrl: parseImages(data.obj("coverArt")?.arr("sources")).first?.url,
                                       albumType: data.str("type")?.lowercased(),
                                       pinned: pinned, addedAt: addedAt)
        }
        if has("Artist") {
            guard let data = data, let name = data.obj("profile")?.str("name") ?? data.str("name") else { return nil }
            return SpotifyLibraryEntry(kind: .artist, id: id, uri: uri, name: name,
                                       imageUrl: parseImages(data.obj("visuals")?.obj("avatarImage")?.arr("sources")).first?.url,
                                       pinned: pinned, addedAt: addedAt)
        }
        return nil
    }

    /// Вся медиатека целиком (или папка), страницами по 50.
    func myLibraryAll(filter: String? = nil, folderUri: String? = nil) async throws -> [SpotifyLibraryEntry] {
        if yandexIsSource, let y = yandex {
            if folderUri != nil { return [] }
            let all = try await y.library()
            switch filter {
            case "Playlists"?: return all.filter { $0.kind == .playlist || $0.kind == .likedSongs }
            case "Albums"?: return all.filter { $0.kind == .album }
            case "Artists"?: return all.filter { $0.kind == .artist }
            default: return all
            }
        }
        var all: [SpotifyLibraryEntry] = []
        var offset = 0
        while true {
            let page = try await myLibrary(filter: filter, folderUri: folderUri, limit: 50, offset: offset)
            all.append(contentsOf: page.items)
            offset += 50
            if page.items.isEmpty || offset >= page.total || offset >= 2000 { break }
        }
        if filter == nil && folderUri == nil {
            libraryLock.lock()
            libraryIds = Set(all.map { $0.id })
            libraryLoaded = true
            libraryLock.unlock()
        }
        return all
    }

    // Что лежит в медиатеке аккаунта (из последней загрузки) — для ♥ альбома и «Вы подписаны»:
    // REST `me/…/contains` веб-токену часто отказывает, как и на Android.
    private var libraryIds = Set<String>()
    private var libraryLoaded = false
    private let libraryLock = NSLock()

    func inLibrary(_ id: String) async -> Bool {
        libraryLock.lock(); let loaded = libraryLoaded; libraryLock.unlock()
        if !loaded { _ = try? await myLibraryAll() }
        libraryLock.lock(); defer { libraryLock.unlock() }
        return libraryIds.contains(id)
    }

    func noteLibrary(_ id: String, _ inside: Bool) {
        libraryLock.lock()
        if inside { libraryIds.insert(id) } else { libraryIds.remove(id) }
        libraryLock.unlock()
    }

    // MARK: Плейлист (fetchPlaylist)

    func playlist(_ playlistId: String) async throws -> SpotifyPlaylist {
        if YandexIds.isYandex(playlistId), let y = yandex { return try await y.playlist(playlistId) }
        let vars: JSONObject = ["uri": "spotify:playlist:\(playlistId)", "offset": 0, "limit": 25, "enableWatchFeedEntrypoint": true]
        let response = try await graphqlPost("fetchPlaylist", variables: vars)
        guard let p = response.obj("data")?.obj("playlistV2") else {
            throw SpotifyError(statusCode: 500, message: "Invalid fetchPlaylist response")
        }
        let owner = p.obj("ownerV2")?.obj("data")
        let ownerUri = owner?.str("uri") ?? ""
        var playlist = SpotifyPlaylist()
        playlist.id = playlistId
        playlist.name = p.str("name") ?? ""
        playlist.description = p.str("description")
        playlist.images = parseImages(p.obj("images")?.objects("items").first?.arr("sources"))
        playlist.owner = SpotifyPlaylistOwner(id: ownerUri.substringAfterLast(":"), displayName: owner?.str("name"),
                                              uri: ownerUri.isEmpty ? nil : ownerUri)
        playlist.totalTracks = p.obj("content")?.int("totalCount") ?? 0
        playlist.uri = "spotify:playlist:\(playlistId)"
        playlist.collaborative = (p.obj("members")?.arr("items")?.count ?? 0) > 1
        return playlist
    }

    func playlistTracks(_ playlistId: String, limit: Int = 100, offset: Int = 0) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        if YandexIds.isYandex(playlistId), let y = yandex { return try await y.playlistTracks(playlistId, limit: limit, offset: offset) }
        let vars: JSONObject = ["uri": "spotify:playlist:\(playlistId)", "offset": offset, "limit": limit, "enableWatchFeedEntrypoint": false]
        let response = try await graphqlPost("fetchPlaylist", variables: vars)
        guard let content = response.obj("data")?.obj("playlistV2")?.obj("content") else {
            throw SpotifyError(statusCode: 500, message: "No content in fetchPlaylist response")
        }
        let tracks = content.objects("items").compactMap { item -> SpotifyPlaylistTrack? in
            guard let wrapper = item.obj("itemV2"), let data = wrapper.obj("data") else { return nil }
            let wrapperUri = wrapper.str("_uri") ?? wrapper.str("uri")
            return SpotifyPlaylistTrack(addedAt: item.obj("addedAt")?.str("isoString"),
                                        track: parseTrack(data, uriOverride: wrapperUri),
                                        uid: item.str("uid") ?? wrapper.str("uid"))
        }
        return SpotifyPaging(items: tracks, total: content.int("totalCount") ?? 0, limit: limit, offset: offset)
    }

    // MARK: Любимые треки (fetchLibraryTracks)

    func likedSongs(limit: Int = 50, offset: Int = 0) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        if yandexIsSource, let y = yandex { return try await y.likedSongs(limit: limit, offset: offset) }
        let response = try await graphqlPost("fetchLibraryTracks", variables: ["offset": offset, "limit": limit])
        guard let tracksData = response.obj("data")?.obj("me")?.obj("library")?.obj("tracks") else {
            throw SpotifyError(statusCode: 500, message: "Invalid fetchLibraryTracks response")
        }
        let tracks = tracksData.objects("items").compactMap { item -> SpotifyPlaylistTrack? in
            guard let wrapper = item.obj("track"), let data = wrapper.obj("data") else { return nil }
            let wrapperUri = wrapper.str("_uri") ?? wrapper.str("uri")
            return SpotifyPlaylistTrack(addedAt: item.obj("addedAt")?.str("isoString"),
                                        track: parseTrack(data, uriOverride: wrapperUri), uid: nil)
        }
        return SpotifyPaging(items: tracks, total: tracksData.int("totalCount") ?? 0, limit: limit, offset: offset)
    }

    // MARK: Альбом (getAlbum)

    /// Альбом с кэшем (Android 2.2.5: альбомы в кэше, открываются без сети): свежий из памяти/диска — сразу,
    /// иначе из сети; нет сети — последний сохранённый.
    func album(_ albumId: String) async throws -> SpotifyAlbum {
        if let hit = AlbumCache.shared.get(albumId, maxAge: 6 * 3600) { return hit }
        do {
            let a = try await fetchAlbum(albumId)
            AlbumCache.shared.put(a)
            return a
        } catch {
            if let stale = AlbumCache.shared.get(albumId, maxAge: .infinity) { return stale }
            throw error
        }
    }

    private func fetchAlbum(_ albumId: String) async throws -> SpotifyAlbum {
        if YandexIds.isYandex(albumId), let y = yandex { return try await y.album(albumId) }
        let vars: JSONObject = ["uri": "spotify:album:\(albumId)", "locale": "", "offset": 0, "limit": 50]
        let response = try await graphqlPost("getAlbum", variables: vars)
        guard let data = response.obj("data")?.obj("albumUnion") else {
            throw SpotifyError(statusCode: 500, message: "Invalid getAlbum response")
        }
        let artists = (data.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist)
        let images = parseImages(data.obj("coverArt")?.arr("sources"))
        let simple = SpotifySimpleAlbum(id: albumId, name: data.str("name") ?? "", images: images,
                                        releaseDate: data.obj("date")?.str("isoString"),
                                        albumType: data.str("type")?.lowercased(), artists: artists,
                                        uri: "spotify:album:\(albumId)")
        let tracksData = data.obj("tracksV2")
        var album = SpotifyAlbum()
        album.id = albumId
        album.name = simple.name
        album.albumType = simple.albumType
        album.artists = artists
        album.images = images
        album.releaseDate = simple.releaseDate
        album.totalTracks = tracksData?.int("totalCount") ?? 0
        album.tracks = (tracksData?.objects("items") ?? []).compactMap { item in
            item.obj("track").map { parseTrack($0, albumOverride: simple) }
        }
        album.uri = simple.uri
        return album
    }

    // MARK: Артист (queryArtistOverview)

    private let artistCacheLock = NSLock()
    private var artistCache: [String: (at: Date, union: JSONObject)] = [:]

    /// Один ответ queryArtistOverview питает профиль, дискографию, топ и похожих: держим его 5 минут.
    private func artistUnion(_ artistId: String) async throws -> JSONObject {
        artistCacheLock.lock()
        let cached = artistCache[artistId]
        if artistCache.count > 50 { artistCache.removeAll() }
        artistCacheLock.unlock()
        if let cached = cached, Date().timeIntervalSince(cached.at) < 300 { return cached.union }

        let response = try await graphqlPost("queryArtistOverview", variables: ["uri": "spotify:artist:\(artistId)", "locale": ""])
        guard let union = response.obj("data")?.obj("artistUnion") else {
            throw SpotifyError(statusCode: 500, message: "Invalid queryArtistOverview response")
        }
        artistCacheLock.lock()
        artistCache[artistId] = (Date(), union)
        artistCacheLock.unlock()
        return union
    }

    /// Описание артиста без HTML-ссылок и сущностей.
    static func plainText(_ html: String?) -> String? {
        guard var t = html, !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] { t = t.replacingOccurrences(of: k, with: v) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func artist(_ artistId: String) async throws -> SpotifyArtist {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.artist(artistId) }
        let data = try await artistUnion(artistId)
        return SpotifyArtist(id: artistId, name: data.obj("profile")?.str("name") ?? "",
                             images: parseImages(data.obj("visuals")?.obj("avatarImage")?.arr("sources")),
                             uri: "spotify:artist:\(artistId)",
                             monthlyListeners: data.obj("stats")?.int("monthlyListeners"),
                             followers: data.obj("stats")?.int("followers"),
                             biography: Self.plainText(data.obj("profile")?.obj("biography")?.str("text")))
    }

    func artistDiscography(_ artistId: String) async throws -> SpotifyArtistDiscography {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.artistDiscography(artistId) }
        let disco = try await artistUnion(artistId).obj("discography")
        func group(_ key: String, _ type: String) -> [SpotifyAlbum] {
            var seen = Set<String>()
            return (disco?.obj(key)?.objects("items") ?? []).compactMap { item -> SpotifyAlbum? in
                // Элемент дискографии оборачивает список релизов: берём основной.
                let release = item.obj("releases")?.objects("items").first ?? item
                guard let album = parseRelease(release, type: type), seen.insert(album.id).inserted else { return nil }
                return album
            }
        }
        return SpotifyArtistDiscography(
            albums: group("albums", "album"),
            singles: group("singles", "single"),
            compilations: group("compilations", "compilation"),
            latest: disco?.obj("latest").flatMap { parseRelease($0, type: $0.str("type")?.lowercased() ?? "album") }
        )
    }

    /// Релизы других артистов с участием этого (Spotify «Appears On», `relatedContent.appearsOn`), с их артистами.
    func artistAppearsOn(_ artistId: String) async throws -> [SpotifyAlbum] {
        if YandexIds.isYandex(artistId) { return [] }
        var seen = Set<String>()
        return (try await artistUnion(artistId).obj("relatedContent")?.obj("appearsOn")?.objects("items") ?? []).compactMap { item -> SpotifyAlbum? in
            let release = item.obj("releases")?.objects("items").first ?? item
            guard var album = parseRelease(release, type: release.str("type")?.lowercased() ?? "album"), seen.insert(album.id).inserted else { return nil }
            album.artists = (release.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist)
            return album
        }
    }

    func artistTopTracks(_ artistId: String) async throws -> [SpotifyTrack] {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.artistTopTracks(artistId) }
        let items = try await artistUnion(artistId).obj("discography")?.obj("topTracks")?.objects("items") ?? []
        return items.compactMap { $0.obj("track").map { parseTrack($0) } }
    }

    func artistRelatedArtists(_ artistId: String) async throws -> [SpotifyArtist] {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.similarArtists(artistId) }
        let items = try await artistUnion(artistId).obj("relatedContent")?.obj("relatedArtists")?.objects("items") ?? []
        return items.compactMap { item in
            guard let uri = item.str("uri"), let name = item.obj("profile")?.str("name") else { return nil }
            return SpotifyArtist(id: uri.substringAfterLast(":"), name: name,
                                 images: parseImages(item.obj("visuals")?.obj("avatarImage")?.arr("sources")), uri: uri)
        }
    }

    // MARK: - Поиск (GQL: searchDesktop)

    func search(_ query: String, limit: Int = 20, offset: Int = 0) async throws -> SpotifySearchResult {
        if yandexIsSource, let y = yandex { return try await y.search(query, limit: limit) }
        let vars: JSONObject = [
            "searchTerm": query, "offset": offset, "limit": limit, "numberOfTopResults": 5,
            "includeAudiobooks": false, "includeArtistHasConcertsField": false, "includePreReleases": false,
            "includeLocalConcertsField": false, "includeAuthors": false,
        ]
        let response = try await graphqlPost("searchDesktop", variables: vars)
        guard let data = response.obj("data")?.obj("searchV2") else {
            throw SpotifyError(statusCode: 500, message: "Invalid searchDesktop response")
        }
        var result = SpotifySearchResult()
        let tracksSection = data.obj("tracksV2")
        for elem in tracksSection?.objects("items") ?? [] {
            guard let wrapper = elem.obj("item"), wrapper.str("__typename") == "TrackResponseWrapper",
                  let d = wrapper.obj("data"), d.str("__typename") == "Track" else { continue }
            result.tracks.append(parseTrack(d, uriOverride: wrapper.str("_uri") ?? wrapper.str("uri")))
        }
        result.tracksTotal = tracksSection?.int("totalCount") ?? 0
        for w in data.obj("albumsV2")?.objects("items") ?? [] {
            guard w.str("__typename") == "AlbumResponseWrapper", let d = w.obj("data"), d.str("__typename") == "Album" else { continue }
            let uri = d.str("uri") ?? ""
            result.albums.append(SpotifyAlbum(
                id: uri.substringAfterLast(":"), name: d.str("name") ?? "", albumType: d.str("type")?.lowercased(),
                artists: (d.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist),
                images: parseImages(d.obj("coverArt")?.arr("sources")),
                releaseDate: d.obj("date")?.int("year").map(String.init), uri: uri.isEmpty ? nil : uri))
        }
        for w in data.obj("artists")?.objects("items") ?? [] {
            guard w.str("__typename") == "ArtistResponseWrapper", let d = w.obj("data"), d.str("__typename") == "Artist" else { continue }
            let uri = d.str("uri") ?? ""
            result.artists.append(SpotifyArtist(
                id: uri.substringAfterLast(":"), name: d.obj("profile")?.str("name") ?? "",
                images: parseImages(d.obj("visuals")?.obj("avatarImage")?.arr("sources")), uri: uri.isEmpty ? nil : uri))
        }
        for w in data.obj("playlists")?.objects("items") ?? [] {
            guard w.str("__typename") == "PlaylistResponseWrapper", let d = w.obj("data"), d.str("__typename") == "Playlist" else { continue }
            let uri = d.str("uri") ?? ""
            let owner = d.obj("ownerV2")?.obj("data")
            let ownerUri = owner?.str("uri") ?? ""
            result.playlists.append(SpotifyPlaylist(
                id: uri.substringAfterLast(":"), name: d.str("name") ?? "", description: d.str("description"),
                images: parsePlaylistImages(d.obj("images")),
                owner: SpotifyPlaylistOwner(id: ownerUri.substringAfterLast(":"), displayName: owner?.str("name"),
                                            uri: ownerUri.isEmpty ? nil : ownerUri),
                uri: uri.isEmpty ? nil : uri))
        }
        return result
    }

    // MARK: - Один трек (REST: tracks/<id>)

    func track(_ trackId: String) async throws -> SpotifyTrack {
        if YandexIds.isYandex(trackId), let y = yandex { if let t = try await y.tracks([YandexIds.raw(trackId)]).first { return t }; throw YandexError(status: 404, message: "Track not found") }
        let data = try await restGet("tracks/\(trackId)")
        guard let o = JSON.object(data) else { throw SpotifyError(statusCode: 500, message: "Invalid track response") }
        func images(_ list: [JSONObject]) -> [SpotifyImage] {
            list.compactMap { i in i.str("url").map { SpotifyImage(url: $0, height: i.int("height"), width: i.int("width")) } }
        }
        let al = o.obj("album")
        let album = al.map {
            SpotifySimpleAlbum(id: $0.str("id") ?? "", name: $0.str("name") ?? "", images: images($0.objects("images")),
                               releaseDate: $0.str("release_date"), albumType: $0.str("album_type"), artists: [], uri: $0.str("uri"))
        }
        return SpotifyTrack(
            id: o.str("id") ?? trackId, name: o.str("name") ?? "",
            artists: o.objects("artists").map { SpotifySimpleArtist(id: $0.str("id"), name: $0.str("name") ?? "", uri: $0.str("uri")) },
            album: album, durationMs: o.int("duration_ms") ?? 0, explicit: o.bool("explicit") ?? false, isLocal: false,
            trackNumber: o.int("track_number"), uri: o.str("uri"), popularity: o.int("popularity"),
            isrc: o.obj("external_ids")?.str("isrc"), playCount: nil)
    }

    // MARK: - Лайки (GQL: addToLibrary / removeFromLibrary; REST me/tracks — запасной путь)

    func addToLibrary(_ uris: [String]) async throws {
        _ = try await graphqlPost("addToLibrary", variables: ["libraryItemUris": uris])
    }

    func removeFromLibrary(_ uris: [String]) async throws {
        _ = try await graphqlPost("removeFromLibrary", variables: ["libraryItemUris": uris])
    }

    /// Токен веб-плеера на многих аккаунтах не принимает запись через публичный REST, поэтому сначала мутация веб-плеера.
    func saveTrack(_ trackId: String) async throws {
        if YandexIds.isYandex(trackId), let y = yandex { return try await y.setLiked("track", id: trackId, liked: true) }
        do {
            try await addToLibrary(["spotify:track:\(trackId)"])
        } catch {
            try await restWrite("PUT", "me/tracks?ids=\(trackId)")
        }
    }

    func removeTrack(_ trackId: String) async throws {
        if YandexIds.isYandex(trackId), let y = yandex { return try await y.setLiked("track", id: trackId, liked: false) }
        do {
            try await removeFromLibrary(["spotify:track:\(trackId)"])
        } catch {
            try await restWrite("DELETE", "me/tracks?ids=\(trackId)")
        }
    }

    func setFollowingArtist(_ artistId: String, follow: Bool) async throws {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.setLiked("artist", id: artistId, liked: follow) }
        try await restWrite(follow ? "PUT" : "DELETE", "me/following?type=artist&ids=\(artistId)")
        noteLibrary(artistId, follow)
    }

    func isFollowingArtist(_ artistId: String) async throws -> Bool {
        if YandexIds.isYandex(artistId), let y = yandex { return try await y.isArtistLiked(artistId) }
        if await inLibrary(artistId) { return true }
        guard let data = try? await restGet("me/following/contains?type=artist&ids=\(artistId)") else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [Bool])?.first ?? false
    }

    func setAlbumSaved(_ albumId: String, saved: Bool) async throws {
        if YandexIds.isYandex(albumId), let y = yandex { return try await y.setLiked("album", id: albumId, liked: saved) }
        try await restWrite(saved ? "PUT" : "DELETE", "me/albums?ids=\(albumId)")
        noteLibrary(albumId, saved)
    }

    func isAlbumSaved(_ albumId: String) async throws -> Bool {
        if YandexIds.isYandex(albumId), let y = yandex { return try await y.isAlbumLiked(albumId) }
        if await inLibrary(albumId) { return true }
        guard let data = try? await restGet("me/albums/contains?ids=\(albumId)") else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [Bool])?.first ?? false
    }

    /// Какие из треков лежат в «Любимых треках» аккаунта (по 50 за запрос).
    func tracksSaved(_ trackIds: [String]) async throws -> [String: Bool] {
        if let y = yandex, trackIds.contains(where: { YandexIds.isYandex($0) }) {
            var result: [String: Bool] = [:]
            let liked = Set((try? await y.likedTrackRefs())?.map { YandexIds.make($0.id) } ?? [])
            for id in trackIds where YandexIds.isYandex(id) { result[id] = liked.contains(id) }
            let rest = trackIds.filter { !YandexIds.isYandex($0) }
            if !rest.isEmpty {
                for (k, v) in try await tracksSavedSpotify(rest) { result[k] = v }
            }
            return result
        }
        return try await tracksSavedSpotify(trackIds)
    }

    private func tracksSavedSpotify(_ trackIds: [String]) async throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        var unique: [String] = []
        for id in trackIds where !unique.contains(id) { unique.append(id) }
        var start = 0
        while start < unique.count {
            let chunk = Array(unique[start..<min(start + 50, unique.count)])
            start += 50
            let data = try await restGet("me/tracks/contains?ids=\(chunk.joined(separator: ","))")
            let flags = ((try? JSONSerialization.jsonObject(with: data)) as? [Bool]) ?? []
            for (i, id) in chunk.enumerated() { result[id] = i < flags.count ? flags[i] : false }
        }
        return result
    }

    private func restWrite(_ method: String, _ endpoint: String) async throws {
        guard let token = await tokens.token() else { throw SpotifyError(statusCode: 401, message: "Not authenticated") }
        guard let url = URL(string: Self.restBase + endpoint) else { throw SpotifyError(statusCode: 400, message: "Bad endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (k, v) in baseHeaders(token: token) { request.setValue(v, forHTTPHeaderField: k) }
        let r = try await HTTP.send(request)
        if !r.isSuccess { throw SpotifyError(statusCode: r.status, message: "Spotify API error \(r.status)") }
    }

    // MARK: - Главная (GQL: home) — персональная лента: миксы, «Радар новинок», «Вернуться к…» и т. д.

    func home(sectionItemsLimit: Int = 10, language: String? = nil) async throws -> SpotifyHomeFeed {
        let vars: JSONObject = [
            "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER", "timeZone": TimeZone.current.identifier, "sp_t": "", "facet": "",
            "sectionItemsLimit": sectionItemsLimit, "includeEpisodeContentRatingsV2": false,
        ]
        let response = try await graphqlPost("home", variables: vars, language: language)
        guard let home = response.obj("data")?.obj("home") else { throw SpotifyError(statusCode: 500, message: "Invalid home response") }
        var feed = SpotifyHomeFeed(greeting: home.obj("greeting")?.str("transformedLabel"), sections: [])
        for section in home.obj("sectionContainer")?.obj("sections")?.objects("items") ?? [] {
            guard let data = section.obj("data"), let typename = data.str("__typename"),
                  let raw = section.obj("sectionItems")?.objects("items") else { continue }
            let t = data.obj("title")
            let items = raw.compactMap(parseHomeItem)
            if items.isEmpty { continue }
            feed.sections.append(SpotifyHomeSection(
                uri: section.str("uri") ?? "", title: t?.str("transformedLabel") ?? t?.str("translatedBaseText") ?? t?.str("text"),
                typename: typename, items: items))
        }
        return feed
    }

    // MARK: - Новинки подписок (GQL: queryWhatsNewFeed), как `Spotify.newReleases`

    func newReleases(limit: Int = 20, offset: Int = 0) async throws -> SpotifyPaging<SpotifyAlbum> {
        let vars: JSONObject = ["offset": offset, "limit": limit, "onlyUnPlayedItems": false, "includedContentTypes": ["ALBUM"]]
        let response = try await graphqlPost("queryWhatsNewFeed", variables: vars)
        guard let feed = response.obj("data")?.obj("whatsNewFeedItems") else {
            throw SpotifyError(statusCode: 500, message: "Invalid queryWhatsNewFeed response")
        }
        let albums = feed.objects("items").compactMap { item -> SpotifyAlbum? in
            guard let content = item.obj("content"), content.str("__typename") == "AlbumResponseWrapper",
                  let data = content.obj("data"), data.str("__typename") == "Album", let uri = data.str("uri") else { return nil }
            return SpotifyAlbum(id: uri.substringAfterLast(":"), name: data.str("name") ?? "", albumType: data.str("albumType")?.lowercased(),
                                artists: (data.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist),
                                images: parseImages(data.obj("coverArt")?.arr("sources")),
                                releaseDate: data.obj("date")?.str("isoString"), uri: uri)
        }
        return SpotifyPaging(items: albums, total: feed.int("totalCount") ?? 0, limit: limit, offset: offset)
    }

    private func parseHomeItem(_ item: JSONObject) -> SpotifyHomeItem? {
        guard let content = item.obj("content"), let wrapper = content.str("__typename"),
              let data = content.obj("data"), let uri = data.str("uri") else { return nil }
        let id = uri.substringAfterLast(":")
        switch wrapper {
        case "PlaylistResponseWrapper":
            let image = data.obj("images")?.objects("items").first?.objects("sources").first?.str("url")
            let owner = data.obj("ownerV2")?.obj("data")?.str("name")
            let madeFor = data.objects("attributes").first { $0.str("key") == "madeFor.username" }?.str("value")
            return SpotifyHomeItem(kind: .playlist, id: id, uri: uri, name: data.str("name") ?? "",
                                   subtitle: data.str("description") ?? owner, imageUrl: image, owner: owner, madeFor: madeFor)
        case "AlbumResponseWrapper":
            let artists = (data.obj("artists")?.objects("items") ?? []).compactMap(parseSimpleArtist).map { $0.name }
            return SpotifyHomeItem(kind: .album, id: id, uri: uri, name: data.str("name") ?? "",
                                   subtitle: artists.joined(separator: ", "),
                                   imageUrl: data.obj("coverArt")?.objects("sources").first?.str("url"))
        case "ArtistResponseWrapper":
            return SpotifyHomeItem(kind: .artist, id: id, uri: uri, name: data.obj("profile")?.str("name") ?? "", subtitle: nil,
                                   imageUrl: data.obj("visuals")?.obj("avatarImage")?.objects("sources").first?.str("url"))
        default:
            return nil
        }
    }
}


/// Кэш альбомов: память + `Caches/albums/<id>.json`.
final class AlbumCache {
    static let shared = AlbumCache()
    private var memory: [String: (Date, SpotifyAlbum)] = [:]
    private let lock = NSLock()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("albums", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ id: String) -> URL { dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json") }

    func get(_ id: String, maxAge: TimeInterval) -> SpotifyAlbum? {
        lock.lock()
        if let (at, a) = memory[id] {
            lock.unlock()
            return Date().timeIntervalSince(at) <= maxAge ? a : nil
        }
        lock.unlock()
        let f = file(id)
        guard let data = try? Data(contentsOf: f), let a = try? JSONDecoder().decode(SpotifyAlbum.self, from: data) else { return nil }
        let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock(); memory[id] = (at, a); lock.unlock()
        return Date().timeIntervalSince(at) <= maxAge ? a : nil
    }

    /// Для первого кадра экрана: любой сохранённый, без сети.
    func any(_ id: String) -> SpotifyAlbum? { get(id, maxAge: .infinity) }

    func put(_ a: SpotifyAlbum) {
        lock.lock()
        memory[a.id] = (Date(), a)
        if memory.count > 300 { memory.removeAll() }
        lock.unlock()
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: file(a.id), options: .atomic) }
    }
}
