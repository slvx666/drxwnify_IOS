import Foundation

/// VK как источник звука — перенос `resolver/providers/VkAudioProvider.kt` (поиск и поток).
/// Свой вход в VK (`vkAccessToken`) или общий демо-аккаунт из `RemoteConfig` с дневным лимитом треков.
final class VkProvider: AudioProvider {
    let id = AudioProviderId.VK
    let searchTimeout: TimeInterval = 15

    /// Версия API официального Android-клиента: токен и версия идут вместе.
    static let apiVersion = "5.116"
    static let oauthClientId = "2274003"
    static let oauthRedirect = "https://oauth.vk.com/blank.html"
    static let oauthURL = "https://oauth.vk.com/authorize?client_id=\(oauthClientId)"
        + "&display=mobile&redirect_uri=\(oauthRedirect)&scope=all&response_type=token&v=\(apiVersion)"
    /// Запросы должны выглядеть как клиент, которому выдан токен, иначе VK отказывает.
    static let clientUserAgent =
        "VKAndroidApp/5.52-4543 (Android 5.1.1; SDK 22; x86_64; unknown Android SDK built for x86_64; en; 320x240)"

    private static let urlTTL: TimeInterval = 3600
    private static let minCallSpacing: TimeInterval = 0.35
    private static let tooManyRequests = 6
    private static let authFailed = 5
    private static let floodControl = 9
    private static let floodPauseFirst: TimeInterval = 600
    private static let floodPauseMax: TimeInterval = 7200

    struct ApiError: Error, LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { "VK \(code): \(message)" }
    }

    struct Audio {
        var fullId: String
        var title: String
        var artist: String
        var durationSec: Int
        var url: String?
        var thumb: String?
        /// Исполнители с id ВК (только у официальных релизов; у загрузки пользователя — пусто).
        var artistRefs: [ArtistRef] = []
        /// Альбом трека (только у официальных релизов).
        var album: AlbumRef?

        /// «owner_audio» — тот же трек при любом access key.
        var baseId: String { fullId.split(separator: "_").prefix(2).joined(separator: "_") }
    }

    struct ArtistRef: Hashable {
        var id: String?
        var name: String
    }

    struct AlbumRef: Hashable {
        var ownerId: Int
        var id: Int
        var accessKey: String?
        var title: String
        var cover: String?
    }

    private let settings: TypedStore
    private let state = State()

    private actor State {
        var lastCall = Date.distantPast
        var searchPausedUntil = Date.distantPast
        var searchBackoff: TimeInterval = 0
        var urls: [String: (String, Date)] = [:]
        var revoked = Set<String>()

        /// VK разрешает около трёх вызовов в секунду на токен.
        func waitTurn() async {
            let wait = lastCall.addingTimeInterval(VkProvider.minCallSpacing).timeIntervalSinceNow
            lastCall = Date().addingTimeInterval(max(0, wait))
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        func flooded() {
            searchBackoff = searchBackoff == 0 ? VkProvider.floodPauseFirst : min(searchBackoff * 2, VkProvider.floodPauseMax)
            searchPausedUntil = Date().addingTimeInterval(searchBackoff)
        }
        func searchOk() { searchBackoff = 0 }
        func remember(_ id: String, _ url: String) { urls[id] = (url, Date()) }
        func forget(_ id: String) { urls[id] = nil }
        func cached(_ id: String) -> String? {
            guard let u = urls[id], Date().timeIntervalSince(u.1) < VkProvider.urlTTL else { return nil }
            return u.0
        }
        func revoke(_ token: String) { revoked.insert(token) }
        func isRevoked(_ token: String) -> Bool { revoked.contains(token) }
    }

    init(settings: TypedStore) {
        self.settings = settings
    }

    private var ownToken: String? {
        let t = settings.get(PK.vkAccessToken)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// Свой токен, иначе общий из конфигурации (`SharedVk`).
    private var token: String? { ownToken ?? RemoteConfig.shared.config.vkShared?.token }

    /// Общий аккаунт стоит вместо своего.
    var sharedInUse: Bool { ownToken == nil && RemoteConfig.shared.config.vkShared != nil }

    func isReady() -> Bool { token != nil && SharedVkQuota.hasTracksLeft(inUse: sharedInUse) }

    // MARK: - API

    private func call(_ method: String, _ params: [String: String], timeout: TimeInterval = 12) async throws -> JSONObject {
        guard let token = token else { throw ApiError(code: 0, message: "no token") }
        if await state.isRevoked(token) { throw ApiError(code: Self.authFailed, message: "token revoked") }
        var all = params
        all["access_token"] = token
        all["v"] = Self.apiVersion
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://api.vk.com/method/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let r = try await HTTP.send(request)
        guard r.isSuccess, let root = JSON.object(r.data) else { throw ApiError(code: r.status, message: "HTTP \(r.status)") }
        if let err = root.obj("error") {
            let code = err.int("error_code") ?? 0
            if code == Self.floodControl && method == "audio.search" { await state.flooded() }
            if code == Self.authFailed { await state.revoke(token) }
            throw ApiError(code: code, message: err.str("error_msg") ?? "")
        }
        if method == "audio.search" { await state.searchOk() }
        return root
    }

    private func throttled(_ method: String, _ params: [String: String], timeout: TimeInterval = 12) async throws -> JSONObject {
        await state.waitTurn()
        do {
            return try await call(method, params, timeout: timeout)
        } catch let e as ApiError where e.code == Self.tooManyRequests {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await call(method, params, timeout: timeout)
        }
    }

    private static let m3u8ToMp3 = try! NSRegularExpression(pattern: "/[0-9a-f]+(/audios)?/([0-9a-f]+)/index\\.m3u8")

    /// VK отдаёт HLS почти для всех треков; тот же файл лежит рядом обычным MP3.
    static func toMp3Url(_ url: String) -> String {
        guard url.contains("index.m3u8") else { return url }
        return m3u8ToMp3.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "$1/$2.mp3")
    }

    private func parse(_ o: JSONObject) -> Audio? {
        guard let id = o.int("id"), id != 0, let owner = o.int("owner_id"), owner != 0 else { return nil }
        let accessKey = o.str("access_key").flatMap { $0.isEmpty ? nil : $0 }
        var title = o.str("title") ?? ""
        if let sub = o.str("subtitle"), !sub.isEmpty, title.range(of: sub, options: .caseInsensitive) == nil { title += " (\(sub))" }
        let main = o.objects("main_artists").compactMap { $0.str("name") }.filter { !$0.isEmpty }
        let thumb = o.obj("album")?.obj("thumb")?.str("photo_300")
        // Официальный релиз называет исполнителей с id ВК и свой альбом; загрузка пользователя — только текст «artist».
        var refs: [ArtistRef] = []
        for key in ["main_artists", "featured_artists"] {
            for a in o.objects(key) {
                guard let name = a.str("name"), !name.isEmpty, !refs.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
                let aid = a.str("id") ?? a.int("id").map(String.init)
                refs.append(ArtistRef(id: (aid?.isEmpty == false && aid != "0") ? aid : nil, name: name))
            }
        }
        var album: AlbumRef?
        if let a = o.obj("album"), let ao = a.int("owner_id"), ao != 0, let aid = a.int("id"), aid != 0 {
            let t = a.obj("thumb")
            let cover = t?.str("photo_600").flatMap { $0.isEmpty ? nil : $0 } ?? t?.str("photo_300").flatMap { $0.isEmpty ? nil : $0 }
            album = AlbumRef(ownerId: ao, id: aid, accessKey: a.str("access_key").flatMap { $0.isEmpty ? nil : $0 },
                             title: a.str("title") ?? "", cover: cover)
        }
        return Audio(fullId: (["\(owner)_\(id)"] + (accessKey.map { [$0] } ?? [])).joined(separator: "_"),
                     title: title, artist: main.isEmpty ? (o.str("artist") ?? "") : main.joined(separator: ", "),
                     durationSec: o.int("duration") ?? 0,
                     url: o.str("url").flatMap { $0.isEmpty ? nil : Self.toMp3Url($0) },
                     thumb: (thumb?.isEmpty == false) ? thumb : nil,
                     artistRefs: refs, album: album)
    }

    private func fetch(_ text: String, count: Int) async throws -> [Audio] {
        let root = try await throttled("audio.search", ["q": text, "count": String(count), "offset": "0", "auto_complete": "1", "sort": "2"])
        return (root.obj("response")?.objects("items") ?? []).compactMap(parse)
    }

    // MARK: - Поиск

    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        try await uploads(q, limit: 1).first
    }

    /// Загрузки трека в VK, лучшая первой.
    func uploads(_ q: AudioQuery, limit: Int = 5) async throws -> [ProviderMatch] {
        guard isReady() else { return [] }
        if await state.searchPausedUntil > Date() { throw ApiError(code: Self.floodControl, message: "search paused (flood control)") }
        let text = q.searchText
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let items = try await fetch(text, count: 30)
        let ranked = FuzzyTrackMatch.ranked(
            artist: q.artists.joined(separator: ", "), title: q.title, durationSec: q.durationMs > 0 ? q.durationMs / 1000 : nil,
            candidates: items.map {
                FuzzyTrackMatch.Candidate(id: $0.fullId, title: $0.title, artists: FuzzyTrackMatch.splitArtists($0.artist) + [$0.artist],
                                          durationSec: $0.durationSec > 0 ? $0.durationSec : nil)
            }, maxDurationGap: YouTubeProvider.uploadDurationTolerance)
        var out: [ProviderMatch] = []
        for s in ranked.prefix(limit) {
            guard let a = items.first(where: { $0.fullId == s.id }), !q.excludedTrackIds.contains(a.fullId) else { continue }
            if let u = a.url { await state.remember(a.fullId, u) }
            out.append(ProviderMatch(provider: id, trackId: a.fullId, title: a.title, artist: a.artist, durationMs: a.durationSec * 1000,
                                     confidence: min(s.score, 1.0), thumbnailUrl: a.thumb, qualityKbps: nil))
        }
        return out
    }

    // MARK: - Поток

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        // Дневные треки общего аккаунта кончились — источник пропускается, но не забывается.
        guard SharedVkQuota.allowTrack(inUse: sharedInUse, trackId: match.trackId) else { return nil }
        var url = await state.cached(match.trackId)
        if url == nil {
            let root = try await throttled("audio.getById", ["audios": match.trackId], timeout: 8)
            url = (root.arr("response")?.first as? JSONObject).flatMap(parse)?.url
            if let u = url { await state.remember(match.trackId, u) }
        }
        guard let s = url, let u = URL(string: s) else { return nil }
        // Проверяем сам адрес: удалённая загрузка отвечает 404, недоступный сервер — ошибкой.
        var head = URLRequest(url: u)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        head.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        guard let r = try? await HTTP.send(head), r.status < 400 else {
            await state.forget(match.trackId)
            return nil
        }
        let length = r.header("Content-Length").flatMap { Int($0) } ?? 0
        let seconds = (match.durationMs ?? q.durationMs) / 1000
        // Битрейт VK не сообщает: считаем по размеру файла, если он известен.
        let bitrate = (length > 0 && seconds > 0 && !s.contains(".m3u8")) ? length * 8 / seconds : 0
        return AudioStream(url: u, mimeType: "audio/mpeg", codecs: "mp3", bitrate: bitrate,
                           expiresAt: Date().addingTimeInterval(Self.urlTTL),
                           headers: ["User-Agent": Self.clientUserAgent], isHLS: s.contains(".m3u8"))
    }

    // MARK: - Проверка доступа после входа

    enum Access {
        case ok(Int)
        case failed(Int?, String)
        case noToken
    }

    /// Один запрос к аудио с сохранённым токеном: «VK ничего не находит» перестаёт быть догадкой.
    func checkAudioAccess() async -> Access {
        guard ownToken != nil else { return .noToken }
        do {
            let root = try await call("audio.search", ["q": "Beatles", "count": "1"])
            return .ok(root.obj("response")?.int("count") ?? 0)
        } catch let e as ApiError {
            return .failed(e.code, e.message)
        } catch {
            return .failed(nil, error.localizedDescription)
        }
    }
}

/// Общий аккаунт VK для тех, кто не привязал свой, — перенос `resolver/SharedVk.kt`.
/// Только прослушивание и дневной лимит треков на телефон; один и тот же трек за день считается один раз.
enum SharedVkQuota {
    private static let defaults = UserDefaults(suiteName: "sp.shared_vk") ?? .standard
    private static let lock = NSLock()

    private static var today: Int { Int(Date().timeIntervalSince1970 / 86400) }

    static func hasTracksLeft(inUse: Bool) -> Bool {
        guard inUse, let limit = RemoteConfig.shared.config.vkShared?.dailyTracks else { return true }
        lock.lock()
        defer { lock.unlock() }
        let used = defaults.integer(forKey: "day") == today ? defaults.integer(forKey: "count") : 0
        return used < limit
    }

    static func allowTrack(inUse: Bool, trackId: String) -> Bool {
        guard inUse, let limit = RemoteConfig.shared.config.vkShared?.dailyTracks else { return true }
        lock.lock()
        defer { lock.unlock() }
        let sameDay = defaults.integer(forKey: "day") == today
        let counted = sameDay ? (defaults.stringArray(forKey: "tracks") ?? []) : []
        if counted.contains(trackId) { return true }
        let used = sameDay ? defaults.integer(forKey: "count") : 0
        if used >= limit { return false }
        defaults.set(today, forKey: "day")
        defaults.set(used + 1, forKey: "count")
        defaults.set(counted + [trackId], forKey: "tracks")
        return true
    }
}

// MARK: - Своя музыка VK (вкладка «VK» в библиотеке, LIB-024)

extension VkProvider {
    struct VkPlaylist: Identifiable, Hashable {
        var id: String { "\(ownerId)_\(playlistId)" }
        var playlistId: Int
        var ownerId: Int
        var accessKey: String?
        var title: String
        var subtitle: String
        var count: Int
        var thumb: String?
        var isAlbum: Bool
        var year: Int? = nil
        /// Где лежит копия в своей музыке, если альбом добавлен (не оригинал).
        var libraryOwnerId: Int? = nil
        var libraryId: Int? = nil
    }

    /// Привязан свой аккаунт VK (не общий): только тогда есть своя музыка.
    var hasOwnAccount: Bool { !(settings.get(PK.vkAccessToken) ?? "").isEmpty }
    private var ownerId: String { settings.get(PK.vkUserId) ?? "" }

    /// Трек ВК для плеера: тот же id каталога `src:VK:…`, что у трека из поиска источников (Android 2.3.0) —
    /// звук берётся из этой самой загрузки, без гонки; история, лайки и загрузки у него общие.
    static func track(_ a: Audio) -> Track {
        Track(VkCatalog.trackOf(a))
    }

    func myTracks(offset: Int = 0, count: Int = 200) async throws -> [Track] {
        var p = ["count": String(count), "offset": String(offset)]
        if !ownerId.isEmpty { p["owner_id"] = ownerId }
        let root = try await throttled("audio.get", p)
        return (root.obj("response")?.objects("items") ?? []).compactMap(parse).map(Self.track)
    }

    func myPlaylists() async throws -> [VkPlaylist] {
        var p = ["count": "100", "offset": "0"]
        if !ownerId.isEmpty { p["owner_id"] = ownerId }
        let root = try await throttled("audio.getPlaylists", p)
        return Self.playlists(root.obj("response")?.objects("items") ?? [])
    }

    /// Разбор плейлистов ВК (как `parsePlaylists` на Android): добавленный альбом — ссылка на оригинал.
    static func playlists(_ items: [JSONObject]) -> [VkPlaylist] {
        var seen = Set<String>()
        return items.compactMap { o -> VkPlaylist? in
            let original = o.obj("original")
            guard let owner = original?.int("owner_id").flatMap({ $0 == 0 ? nil : $0 }) ?? o.int("owner_id"), owner != 0,
                  let id = original?.int("playlist_id").flatMap({ $0 == 0 ? nil : $0 }) ?? o.int("id"), id != 0 else { return nil }
            guard seen.insert("\(owner)_\(id)").inserted else { return nil }
            let key = (original?.str("access_key")).flatMap { $0.isEmpty ? nil : $0 } ?? o.str("access_key").flatMap { $0.isEmpty ? nil : $0 }
            let artists = o.objects("main_artists").compactMap { $0.str("name") }.filter { !$0.isEmpty }
            func photo(_ p: JSONObject?) -> String? {
                p?.str("photo_600").flatMap { $0.isEmpty ? nil : $0 } ?? p?.str("photo_300").flatMap { $0.isEmpty ? nil : $0 }
            }
            let thumb = photo(o.obj("photo")) ?? photo(o.objects("thumbs").first)
            let albumType = o.str("album_type") ?? ""
            // Альбом: `album_type`/`type` 1; у ссылки в своём списке их может не быть — релизы принадлежат сообществу (owner < 0).
            let isAlbum = (o.int("type") ?? 0) == 1 || (!albumType.isEmpty && albumType != "playlist")
                || (albumType.isEmpty && owner < 0 && !artists.isEmpty)
            return VkPlaylist(playlistId: id, ownerId: owner, accessKey: key, title: o.str("title") ?? "",
                              subtitle: artists.joined(separator: ", "), count: o.int("count") ?? 0, thumb: thumb, isAlbum: isAlbum,
                              year: o.int("year").flatMap { $0 > 0 ? $0 : nil },
                              libraryOwnerId: original != nil ? o.int("owner_id") : nil, libraryId: original != nil ? o.int("id") : nil)
        }
    }

    func playlistTracks(_ pl: VkPlaylist) async throws -> [Track] {
        try await playlistAudios(ownerId: pl.ownerId, playlistId: pl.playlistId, accessKey: pl.accessKey).map(Self.track)
    }
}

// MARK: - ВК как каталог (Android 2.3.0 `VkAudioProvider`, раздел «The catalog side»)

extension VkProvider {
    private func items(_ root: JSONObject) -> [Audio] {
        let list: [JSONObject]
        if let arr = root["response"] as? [Any] { list = arr.compactMap { $0 as? JSONObject } } else { list = root.obj("response")?.objects("items") ?? [] }
        let out = list.compactMap(parse)
        VkTrackStore.shared.put(out)
        return out
    }

    func myId() async -> String? {
        let saved = settings.get(PK.vkUserId) ?? ""
        if !saved.isEmpty { return saved }
        guard let r = try? await throttled("users.get", [:]), let id = (r.arr("response")?.first as? JSONObject)?.int("id"), id != 0 else { return nil }
        settings.set(PK.vkUserId, String(id))
        return String(id)
    }

    /// Вся своя музыка (до 5000), новые сверху.
    func myAudios(max: Int = 5000) async throws -> [Audio] {
        guard let owner = await myId() else { return [] }
        var out: [Audio] = []
        var offset = 0
        while offset < max {
            let page = items(try await throttled("audio.get", ["owner_id": owner, "count": "1000", "offset": String(offset)]))
            out += page
            offset += 1000
            if page.count < 1000 { break }
        }
        return out
    }

    func playlistAudios(ownerId: Int, playlistId: Int, accessKey: String?) async throws -> [Audio] {
        var p = ["owner_id": String(ownerId), "playlist_id": String(playlistId), "count": "1000"]
        if let k = accessKey, !k.isEmpty { p["access_key"] = k }
        return items(try await throttled("audio.get", p))
    }

    func playlistById(ownerId: Int, playlistId: Int, accessKey: String?) async throws -> VkPlaylist? {
        var p = ["owner_id": String(ownerId), "playlist_id": String(playlistId)]
        if let k = accessKey, !k.isEmpty { p["access_key"] = k }
        guard let o = try await throttled("audio.getPlaylistById", p).obj("response") else { return nil }
        return Self.playlists([o]).first
    }

    func audiosById(_ fullIds: [String]) async throws -> [Audio] {
        var out: [Audio] = []
        var i = 0
        while i < fullIds.count {
            let chunk = fullIds[i..<min(i + 100, fullIds.count)]
            out += items(try await throttled("audio.getById", ["audios": chunk.joined(separator: ",")]))
            i += 100
        }
        return out
    }

    struct VkArtist {
        var id: String
        var name: String
        var photo: String?
    }

    func artist(_ id: String) async throws -> VkArtist? {
        guard let r = try await throttled("audio.getArtistById", ["artist_id": id]).obj("response"), let name = r.str("name"), !name.isEmpty else { return nil }
        // Самое большое фото до ~1000 px.
        var photo: String?
        let arrays = [r.objects("photo"), r.objects("photos").first?.objects("photo") ?? []]
        for arr in arrays where photo == nil {
            let sizes = arr.compactMap { s -> (String, Int)? in s.str("url").flatMap { $0.isEmpty ? nil : ($0, s.int("width") ?? 0) } }
            photo = sizes.filter { $0.1 <= 1000 }.max { $0.1 < $1.1 }?.0 ?? sizes.first?.0
        }
        return VkArtist(id: id, name: name, photo: photo)
    }

    func artistAudios(_ id: String, count: Int = 50) async throws -> [Audio] {
        var seen = Set<String>()
        return items(try await throttled("audio.getAudiosByArtist", ["artist_id": id, "count": String(count)])).filter { seen.insert($0.fullId).inserted }
    }

    func artistAlbums(_ id: String, count: Int = 100) async throws -> [VkPlaylist] {
        Self.playlists(try await throttled("audio.getAlbumsByArtist", ["artist_id": id, "count": String(count)]).obj("response")?.objects("items") ?? [])
    }

    func recommendationAudios(count: Int = 100) async throws -> [Audio] {
        var seen = Set<String>()
        return items(try await throttled("audio.getRecommendations", ["count": String(count), "shuffle": "0"])).filter { seen.insert($0.fullId).inserted }
    }

    func searchAudios(_ text: String, count: Int) async throws -> [Audio] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        if await state.searchPausedUntil > Date() { throw ApiError(code: Self.floodControl, message: "search paused (flood control)") }
        let list = try await fetch(text, count: max(1, min(200, count)))
        VkTrackStore.shared.put(list)
        return list
    }

    func searchPlaylists(_ text: String, count: Int = 40) async throws -> [VkPlaylist] {
        Self.playlists(try await throttled("audio.searchPlaylists", ["q": text, "count": String(count)]).obj("response")?.objects("items") ?? [])
    }

    /// «+» в ВК: трек в «Мою музыку»; возвращает id копии.
    func addAudio(_ fullId: String) async throws -> Int {
        let parts = fullId.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { throw ApiError(code: 0, message: "bad VK track id") }
        var p = ["owner_id": parts[0], "audio_id": parts[1]]
        if parts.count > 2 { p["access_key"] = parts[2] }
        return try await throttled("audio.add", p).int("response") ?? 0
    }

    func deleteAudio(ownerId: String, audioId: String) async throws {
        _ = try await throttled("audio.delete", ["owner_id": ownerId, "audio_id": audioId])
    }

    func followPlaylist(_ pl: VkPlaylist) async throws {
        var p = ["owner_id": String(pl.ownerId), "playlist_id": String(pl.playlistId)]
        if let k = pl.accessKey, !k.isEmpty { p["access_key"] = k }
        _ = try await throttled("audio.followPlaylist", p)
    }

    func deletePlaylist(ownerId: Int, playlistId: Int) async throws {
        _ = try await throttled("audio.deletePlaylist", ["owner_id": String(ownerId), "playlist_id": String(playlistId)])
    }

    func createPlaylist(_ title: String) async throws -> VkPlaylist? {
        guard let owner = await myId() else { return nil }
        guard let o = try await throttled("audio.createPlaylist", ["owner_id": owner, "title": title, "description": ""]).obj("response") else { return nil }
        return Self.playlists([o]).first
    }

    func addToPlaylist(ownerId: Int, playlistId: Int, audioIds: [String]) async throws {
        guard !audioIds.isEmpty else { return }
        _ = try await throttled("audio.addToPlaylist", ["owner_id": String(ownerId), "playlist_id": String(playlistId),
                                                        "audio_ids": audioIds.joined(separator: ",")])
    }
}

/// Все треки ВК, увиденные за запуск (поиск, медиатека, альбомы): «К альбому/исполнителю» без второго запроса.
final class VkTrackStore {
    static let shared = VkTrackStore()
    private var byId: [String: VkProvider.Audio] = [:]
    private let lock = NSLock()

    func put(_ list: [VkProvider.Audio]) {
        lock.lock(); defer { lock.unlock() }
        if byId.count > 20_000 { byId.removeAll() }
        for a in list { byId[a.baseId] = a }
    }

    func get(_ fullId: String) -> VkProvider.Audio? {
        lock.lock(); defer { lock.unlock() }
        return byId[fullId.split(separator: "_").prefix(2).joined(separator: "_")]
    }
}
