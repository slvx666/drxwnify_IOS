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
        return Audio(fullId: (["\(owner)_\(id)"] + (accessKey.map { [$0] } ?? [])).joined(separator: "_"),
                     title: title, artist: main.isEmpty ? (o.str("artist") ?? "") : main.joined(separator: ", "),
                     durationSec: o.int("duration") ?? 0,
                     url: o.str("url").flatMap { $0.isEmpty ? nil : Self.toMp3Url($0) },
                     thumb: (thumb?.isEmpty == false) ? thumb : nil)
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
    }

    /// Привязан свой аккаунт VK (не общий): только тогда есть своя музыка.
    var hasOwnAccount: Bool { !(settings.get(PK.vkAccessToken) ?? "").isEmpty }
    private var ownerId: String { settings.get(PK.vkUserId) ?? "" }

    static func track(_ a: Audio) -> Track {
        Track(id: "vk:" + a.fullId, catalogId: nil, title: a.title,
              artists: a.artist.components(separatedBy: ", ").filter { !$0.isEmpty }.map { Track.Artist(id: nil, name: $0) },
              albumId: nil, albumName: nil, durationMs: a.durationSec * 1000, artworkUrl: a.thumb)
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
        return (root.obj("response")?.objects("items") ?? []).compactMap { o -> VkPlaylist? in
            guard let id = o.int("id"), let owner = o.int("owner_id") else { return nil }
            let artists = o.objects("main_artists").compactMap { $0.str("name") }.joined(separator: ", ")
            let thumb = o.obj("photo")?.str("photo_300") ?? o.objects("thumbs").first?.str("photo_300")
            let isAlbum = (o.int("type") ?? 0) == 1 || !(o.str("album_type") ?? "").isEmpty && o.str("album_type") != "playlist"
            return VkPlaylist(playlistId: id, ownerId: owner, accessKey: o.str("access_key"), title: o.str("title") ?? "",
                              subtitle: artists, count: o.int("count") ?? 0, thumb: thumb, isAlbum: isAlbum)
        }
    }

    func playlistTracks(_ pl: VkPlaylist) async throws -> [Track] {
        var p = ["owner_id": String(pl.ownerId), "playlist_id": String(pl.playlistId), "count": "500"]
        if let k = pl.accessKey, !k.isEmpty { p["access_key"] = k }
        let root = try await throttled("audio.get", p)
        return (root.obj("response")?.objects("items") ?? []).compactMap(parse).map(Self.track)
    }
}
