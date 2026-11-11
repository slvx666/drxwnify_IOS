import Foundation

/// YouTube как источник звука. Поиск — каталог YouTube Music (клиент WEB_REMIX, фильтр «песни»),
/// поток — цепочка клиентов VISIONOS → ANDROID_VR (как на Android): прямые адреса без подписи и n-параметра.
/// Берётся только `audio/mp4` (AAC): Opus/WebM `AVPlayer` не играет (PLATFORMS).
final class YouTubeProvider: AudioProvider {
    let id = AudioProviderId.YOUTUBE
    let searchTimeout: TimeInterval = 8

    /// Допуск по длине для загрузок, как `ProviderGate.UPLOAD_DURATION_TOLERANCE_S`.
    static let uploadDurationTolerance = 8
    private static let filterSong = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    private static let webUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let remixVersion = "1.20260213.01.00"
    private static let vrVersion = "1.61.48"
    private static let vrUA =
        "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)"

    struct Song {
        var videoId: String
        var title: String
        var artists: [String]
        var durationSec: Int?
        var thumbnail: String?
    }

    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func post(_ url: String, body: JSONObject, headers: [String: String], timeout: TimeInterval) async throws -> JSONObject {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = JSON.data(body)
        let r = try await HTTP.send(request)
        guard r.isSuccess, let o = JSON.object(r.data) else { throw Failure(message: "YouTube HTTP \(r.status)") }
        return o
    }

    // MARK: - Поиск песен в YouTube Music

    func searchSongs(_ text: String) async throws -> [Song] {
        let body: JSONObject = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.remixVersion, "hl": "en", "gl": "US"]],
            "query": text,
            "params": Self.filterSong.removingPercentEncoding ?? Self.filterSong,
        ]
        let root = try await post("https://music.youtube.com/youtubei/v1/search?prettyPrint=false", body: body, headers: [
            "User-Agent": Self.webUA, "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": Self.remixVersion,
            "Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/",
        ], timeout: 7)
        let tabs = root.obj("contents")?.obj("tabbedSearchResultsRenderer")?.objects("tabs") ?? []
        let sections = tabs.first?.obj("tabRenderer")?.obj("content")?.obj("sectionListRenderer")?.objects("contents") ?? []
        var out: [Song] = []
        for section in sections {
            for item in section.obj("musicShelfRenderer")?.objects("contents") ?? [] {
                if let s = Self.parseSong(item) { out.append(s) }
            }
        }
        return out
    }

    private static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, parts.count <= 3, !parts.contains(nil) else { return nil }
        var total = 0
        for p in parts { total = total * 60 + (p ?? 0) }
        return total
    }

    static func parseSong(_ item: JSONObject) -> Song? {
        guard let r = item.obj("musicResponsiveListItemRenderer") else { return nil }
        let columns = r.objects("flexColumns").map {
            $0.obj("musicResponsiveListItemFlexColumnRenderer")?.obj("text")?.objects("runs") ?? []
        }
        guard let videoId = r.obj("playlistItemData")?.str("videoId")
                ?? columns.first?.first?.obj("navigationEndpoint")?.obj("watchEndpoint")?.str("videoId"),
              let title = columns.first?.first?.str("text") else { return nil }
        var artists: [String] = []
        var duration: Int?
        for run in columns.count > 1 ? columns[1] : [] {
            let text = run.str("text") ?? ""
            let pageType = run.obj("navigationEndpoint")?.obj("browseEndpoint")?.obj("browseEndpointContextSupportedConfigs")?
                .obj("browseEndpointContextMusicConfig")?.str("pageType")
            if pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" {
                artists.append(text)
            } else if let d = parseDuration(text) {
                duration = d
            }
        }
        // У части результатов артист идёт без ссылки: тогда это первый отрезок второй колонки.
        if artists.isEmpty, columns.count > 1, let first = columns[1].first?.str("text"), parseDuration(first) == nil {
            artists = [first]
        }
        if duration == nil {
            let fixed = r.objects("fixedColumns").first?.obj("musicResponsiveListItemFixedColumnRenderer")?.obj("text")?.objects("runs").first?.str("text")
            duration = fixed.flatMap(parseDuration)
        }
        let thumbs = r.obj("thumbnail")?.obj("musicThumbnailRenderer")?.obj("thumbnail")?.objects("thumbnails") ?? []
        return Song(videoId: videoId, title: title, artists: artists, durationSec: duration, thumbnail: thumbs.last?.str("url"))
    }

    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        let text = q.searchText
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let songs = try await searchSongs(text)
        let ranked = FuzzyTrackMatch.ranked(
            artist: q.artists.joined(separator: ", "), title: q.title, durationSec: q.durationMs > 0 ? q.durationMs / 1000 : nil,
            candidates: songs.map { FuzzyTrackMatch.Candidate(id: $0.videoId, title: $0.title, artists: $0.artists, durationSec: $0.durationSec) },
            maxDurationGap: Self.uploadDurationTolerance)
        guard let chosen = ranked.first(where: { !q.excludedTrackIds.contains($0.id) }),
              let song = songs.first(where: { $0.videoId == chosen.id }) else { return nil }
        // Совпадение без потока бесполезно: без PoToken YouTube в части сетей отвечает «войдите, чтобы подтвердить, что вы не бот».
        guard let ready = try await stream(videoId: song.videoId) else { return nil }
        await cache.put(song.videoId, ready)
        return ProviderMatch(provider: id, trackId: song.videoId, title: song.title, artist: song.artists.joined(separator: ", "),
                             durationMs: song.durationSec.map { $0 * 1000 }, confidence: min(chosen.score, 1.0),
                             thumbnailUrl: song.thumbnail, qualityKbps: 128)
    }

    // MARK: - Поток

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        if let s = await cache.get(match.trackId) { return s }
        guard let s = try await stream(videoId: match.trackId) else { return nil }
        await cache.put(match.trackId, s)
        return s
    }

    private let cache = StreamCache()

    private actor StreamCache {
        var streams: [String: AudioStream] = [:]
        func put(_ id: String, _ s: AudioStream) { streams[id] = s }
        func get(_ id: String) -> AudioStream? {
            guard let s = streams[id], s.expiresAt > Date().addingTimeInterval(60) else { return nil }
            return s
        }
    }

    /// Клиент `youtubei/v1/player` из `innertube/.../YouTubeClient.kt`.
    struct Client {
        let name: String
        let version: String
        let id: String
        let userAgent: String
        var osName: String?
        var osVersion: String?
        var deviceMake: String?
        var deviceModel: String?
        var androidSdkVersion: Int?
    }

    /// Цепочка как `YTPlayerUtils.STREAM_FALLBACK_CLIENTS` на Android: без PoToken, подписи и n-параметра.
    /// VISIONOS — единственный, что отдаёт файл целиком; дальше ANDROID_VR 1.65.10 (закреп yt-dlp) и старый 1.61.48.
    /// TVHTML5 и WEB_CREATOR требуют входа и шифра, IOS/IPADOS отдают только ~1 МиБ — их нет.
    static let clients: [Client] = [
        Client(name: "VISIONOS", version: "0.1", id: "101",
               userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
               osName: "visionOS", osVersion: "1.3.21O771", deviceMake: "Apple", deviceModel: "RealityDevice14,1"),
        Client(name: "ANDROID_VR", version: "1.65.10", id: "28",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               osName: "Android", osVersion: "12L", deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: 32),
        Client(name: "ANDROID_VR", version: vrVersion, id: "28", userAgent: vrUA,
               osName: "Android", osVersion: "12", deviceMake: "Oculus", deviceModel: "Quest 3", androidSdkVersion: 32),
    ]

    /// Почему YouTube не отдал звук в последний раз (для подсказки «смени сервер VPN», DL-008).
    static var lastBlock: String?

    private let visitor = VisitorData()

    /// `visitorData` из ответа YouTube Music: без него часть клиентов чаще получает «войдите, чтобы подтвердить…».
    private actor VisitorData {
        var value: String?
        var fetchedAt = Date.distantPast
        func get() -> String? { Date().timeIntervalSince(fetchedAt) < 6 * 3600 ? value : nil }
        func set(_ v: String) { value = v; fetchedAt = Date() }
    }

    private func visitorData() async -> String? {
        if let v = await visitor.get() { return v }
        let body: JSONObject = ["context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.remixVersion, "hl": "en", "gl": "US"]],
                                "browseId": "FEmusic_home"]
        guard let root = try? await post("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", body: body, headers: [
            "User-Agent": Self.webUA, "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": Self.remixVersion,
            "Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/",
        ], timeout: 6), let v = root.obj("responseContext")?.str("visitorData"), !v.isEmpty else { return nil }
        await visitor.set(v)
        return v
    }

    /// Прямой адрес AAC для видео: клиенты по очереди, первый с `audio/mp4` побеждает.
    /// nil — видео не играет ни одним клиентом (возраст, регион, «не бот» без VPN, только Opus).
    func stream(videoId: String) async throws -> AudioStream? {
        let visitor = await visitorData()
        var reasons: [String] = []
        for client in Self.clients {
            do {
                if let s = try await stream(videoId: videoId, client: client, visitorData: visitor) {
                    Self.lastBlock = nil
                    return s
                }
                reasons.append("\(client.name) \(client.version): no AAC")
            } catch {
                reasons.append("\(client.name) \(client.version): \(error.localizedDescription)")
            }
        }
        Self.lastBlock = reasons.joined(separator: "; ")
        return nil
    }

    private func stream(videoId: String, client c: Client, visitorData: String?) async throws -> AudioStream? {
        var ctx: JSONObject = ["clientName": c.name, "clientVersion": c.version, "hl": "en", "gl": "US"]
        if let v = c.osName { ctx["osName"] = v }
        if let v = c.osVersion { ctx["osVersion"] = v }
        if let v = c.deviceMake { ctx["deviceMake"] = v }
        if let v = c.deviceModel { ctx["deviceModel"] = v }
        if let v = c.androidSdkVersion { ctx["androidSdkVersion"] = v }
        if let v = visitorData { ctx["visitorData"] = v }
        let body: JSONObject = [
            "context": ["client": ctx],
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
        ]
        var headers = ["User-Agent": c.userAgent, "X-YouTube-Client-Name": c.id, "X-YouTube-Client-Version": c.version]
        if let v = visitorData { headers["X-Goog-Visitor-Id"] = v }
        let root = try await post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", body: body, headers: headers, timeout: 8)
        let status = root.obj("playabilityStatus")?.str("status") ?? "?"
        guard status == "OK", let data = root.obj("streamingData") else {
            throw Failure(message: status)
        }
        var best: (JSONObject, Int)?
        for f in data.objects("adaptiveFormats") + data.objects("formats") {
            guard let mime = f.str("mimeType"), mime.hasPrefix("audio/mp4"), let url = f.str("url"), !url.isEmpty else { continue }
            // Дорожки дубляжа пропускаем: нужна оригинальная.
            if let track = f.obj("audioTrack"), track.bool("audioIsDefault") == false { continue }
            let bitrate = f.int("bitrate") ?? 0
            if best == nil || bitrate > best!.1 { best = (f, bitrate) }
        }
        guard let (f, bitrate) = best, let s = f.str("url"), let url = URL(string: s) else { return nil }
        let ttl = Double(data.int("expiresInSeconds") ?? 21600)
        return AudioStream(url: url, mimeType: "audio/mp4", codecs: "mp4a.40.2", bitrate: bitrate,
                           expiresAt: Date().addingTimeInterval(max(600, ttl - 600)), headers: ["User-Agent": c.userAgent])
    }
}
