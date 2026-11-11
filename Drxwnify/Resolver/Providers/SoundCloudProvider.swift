import Foundation

/// SoundCloud как источник звука — перенос `resolver/providers/SoundCloudAudioProvider.kt`.
/// Публичный web-API с client id самого веб-плеера (берётся со страницы soundcloud.com и кэшируется).
final class SoundCloudProvider: AudioProvider {
    let id = AudioProviderId.SOUNDCLOUD
    let searchTimeout: TimeInterval = 9

    private static let desktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let reuploadDurationToleranceS = 3
    private static let reuploadMaxConfidence = 0.85

    private struct AuthError: Error {}

    private struct ScTrack {
        var id: String
        var title: String
        var artist: String
        var durationMs: Int
        var artwork: String?
        var json: JSONObject
    }

    private let settings: TypedStore
    private let state = State()

    init(settings: TypedStore) {
        self.settings = settings
    }

    /// Изменяемое состояние под актором: client id и кэши.
    private actor State {
        var clientId: String?
        var tracks: [String: JSONObject] = [:]
        var streams: [String: AudioStream] = [:]

        func setClientId(_ id: String?) { clientId = id }
        func cache(_ id: String, _ json: JSONObject) { tracks[id] = json }
        func cacheStream(_ id: String, _ s: AudioStream) { streams[id] = s }
    }

    // MARK: - HTTP и client id

    private func get(_ url: String) async throws -> String? {
        guard let u = URL(string: url) else { return nil }
        let r = try await HTTP.get(u, headers: ["User-Agent": Self.desktopUA, "Accept-Language": "en"], timeout: 8)
        if r.status == 401 || r.status == 403 { throw AuthError() }
        return r.isSuccess ? r.text : nil
    }

    private func currentClientId(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh {
            if let id = await state.clientId { return id }
            if let saved = settings.get(PK.soundCloudClientId), !saved.isEmpty {
                await state.setClientId(saved)
                return saved
            }
        }
        guard let scraped = await scrapeClientId() else { return nil }
        await state.setClientId(scraped)
        settings.set(PK.soundCloudClientId, scraped)
        return scraped
    }

    /// В сборках веб-плеера зашито `client_id:"<32 символа>"`; свежие сборки перечислены последними.
    private func scrapeClientId() async -> String? {
        guard let html = try? await get("https://soundcloud.com/") else { return nil }
        guard let scriptRe = try? NSRegularExpression(pattern: "<script[^>]+src=\"(https://a-v2\\.sndcdn\\.com/assets/[^\"]+\\.js)\""),
              let idRe = try? NSRegularExpression(pattern: "client_id\\s*[:=]\\s*\"?([0-9a-zA-Z]{32})") else { return nil }
        var scripts: [String] = []
        for m in scriptRe.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if let r = Range(m.range(at: 1), in: html) { scripts.append(String(html[r])) }
        }
        for src in scripts.reversed() {
            guard let js = try? await get(src) else { continue }
            if let m = idRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)), let r = Range(m.range(at: 1), in: js) {
                return String(js[r])
            }
        }
        return nil
    }

    /// Запрос к API; если SoundCloud отверг client id — один раз берётся свежий.
    private func withClientId<T>(_ block: (String) async throws -> T?) async throws -> T? {
        guard let cid = await currentClientId() else { return nil }
        do {
            return try await block(cid)
        } catch is AuthError {
            guard let fresh = await currentClientId(forceRefresh: true) else { return nil }
            return try? await block(fresh)
        }
    }

    private func query(_ base: String, _ params: [(String, String)]) -> String {
        var c = URLComponents(string: base)
        var items = c?.queryItems ?? []
        for (k, v) in params {
            items.removeAll { $0.name == k }
            items.append(URLQueryItem(name: k, value: v))
        }
        c?.queryItems = items
        // `+` в значении должен уйти как %2B: URLComponents его не кодирует.
        let encoded = c?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        c?.percentEncodedQuery = encoded
        return c?.url?.absoluteString ?? base
    }

    // MARK: - Поиск

    private func parseTrack(_ o: JSONObject) -> ScTrack? {
        guard let id = o.str("id"), !id.isEmpty else { return nil }
        if (o.str("kind") ?? "track") != "track" { return nil }
        let policy = (o.str("policy") ?? "").uppercased()
        // BLOCK — недоступно в регионе; SNIP — только Go+, открыт 30-секундный отрывок.
        if policy == "BLOCK" || policy == "SNIP" { return nil }
        if o.bool("streamable") == false { return nil }
        let publisher = o.obj("publisher_metadata")?.str("artist") ?? ""
        let uploader = o.obj("user")?.str("username") ?? ""
        let artwork = o.str("artwork_url")
        return ScTrack(id: id, title: o.str("title") ?? "",
                       artist: publisher.trimmingCharacters(in: .whitespaces).isEmpty ? uploader : publisher,
                       durationMs: o.int("full_duration") ?? o.int("duration") ?? 0,
                       artwork: (artwork?.isEmpty == false) ? artwork : nil, json: o)
    }

    private func hasOpenTranscoding(_ t: ScTrack) -> Bool {
        (t.json.obj("media")?.objects("transcodings") ?? []).contains { tr in
            let p = tr.obj("format")?.str("protocol")
            return tr.bool("snipped") != true && (p == "progressive" || p == "hls")
        }
    }

    private func searchTracks(_ text: String, limit: Int = 25) async throws -> [ScTrack] {
        let found: [ScTrack]? = try await withClientId { cid in
            let url = self.query("https://api-v2.soundcloud.com/search/tracks",
                                 [("q", text), ("client_id", cid), ("limit", String(limit)), ("offset", "0"), ("app_locale", "en")])
            guard let body = try await self.get(url), let o = JSON.object(body) else { return nil }
            return o.objects("collection").compactMap(self.parseTrack)
        }
        return (found ?? []).filter(hasOpenTranscoding)
    }

    private static let editMarkers = try! NSRegularExpression(
        pattern: "\\b(flip|edit|re-?edit|rework|vip|remake|extended|club mix|bass ?boost(ed)?|phonk|jersey( club)?|hardstyle|drill|amapiano|[\\p{L}\\p{N}]+ version)\\b")
    private static let sameRecording: Set<String> = ["album version", "original version", "single version", "explicit version"]

    /// Правка / флип / чья-то «версия», которой нет в названии из каталога.
    private func isEdit(of catalogTitle: String, _ uploadTitle: String) -> Bool {
        let upload = FuzzyTrackMatch.allMatches(Self.editMarkers, in: uploadTitle.lowercased()).subtracting(Self.sameRecording)
        if upload.isEmpty { return false }
        return !upload.subtracting(FuzzyTrackMatch.allMatches(Self.editMarkers, in: catalogTitle.lowercased())).isEmpty
    }

    private func nameKey(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Артист целыми словами в названии загрузки или в имени загрузившего.
    private func namesArtist(_ q: AudioQuery, _ t: ScTrack) -> Bool {
        let titleWords = words(t.title)
        let uploader = nameKey(t.artist)
        return q.artists.contains { artist in
            let key = nameKey(artist)
            if key.isEmpty { return false }
            if key == uploader { return true }
            let aw = words(artist)
            guard !aw.isEmpty, titleWords.count >= aw.count else { return false }
            return (0...(titleWords.count - aw.count)).contains { Array(titleWords[$0..<$0 + aw.count]) == aw }
        }
    }

    /// Официальные загрузки (загрузивший = артист) идут раньше перезаливов; перезалив никогда не «уверенное» совпадение.
    private func rank(_ q: AudioQuery, _ tracks: [ScTrack]) -> [(ScTrack, Double)] {
        let usable = tracks.filter { !isEdit(of: q.title, $0.title) }
        let artistKey = nameKey(q.primaryArtist)
        let official = usable.filter { !artistKey.isEmpty && nameKey($0.artist) == artistKey }
        let others = usable.filter { t in !official.contains { $0.id == t.id } }.filter { namesArtist(q, $0) }
        let artist = q.artists.joined(separator: ", ")
        let dur = q.durationMs > 0 ? q.durationMs / 1000 : nil
        func cands(_ list: [ScTrack]) -> [FuzzyTrackMatch.Candidate] {
            list.map { t in
                // Загрузки часто названы «Артист - Название»: артист засчитывается в любом из полей.
                FuzzyTrackMatch.Candidate(id: t.id, title: t.title, artists: [t.artist, t.title],
                                          durationSec: t.durationMs > 0 ? t.durationMs / 1000 : nil)
            }
        }
        let a = FuzzyTrackMatch.ranked(artist: artist, title: q.title, durationSec: dur, candidates: cands(official))
        let b = FuzzyTrackMatch.ranked(artist: artist, title: q.title, durationSec: dur, candidates: cands(others),
                                       maxDurationGap: Self.reuploadDurationToleranceS)
        var out: [(ScTrack, Double)] = []
        for s in a { if let t = tracks.first(where: { $0.id == s.id }) { out.append((t, min(s.score, 1.0))) } }
        for s in b { if let t = tracks.first(where: { $0.id == s.id }) { out.append((t, min(s.score, Self.reuploadMaxConfidence))) } }
        return Array(out.prefix(4))
    }

    /// Поиск с проверкой: релизы лейблов часто отдаются только зашифрованным HLS, поэтому
    /// у лучших совпадений проверяется настоящий открытый поток, и берётся первое играющее.
    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        let text = q.searchText
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        var ranked = rank(q, try await searchTracks(text))
        if ranked.isEmpty {
            let core = FuzzyTrackMatch.titleVariants(q.title).last ?? q.title
            ranked = rank(q, try await searchTracks(core))
        }
        for (track, score) in ranked where !q.excludedTrackIds.contains(track.id) {
            await state.cache(track.id, track.json)
            guard let stream = try await resolveStream(track.json) else { continue }
            await state.cacheStream(track.id, stream)
            return ProviderMatch(provider: id, trackId: track.id, title: track.title, artist: track.artist,
                                 durationMs: track.durationMs, confidence: score, thumbnailUrl: track.artwork, qualityKbps: nil)
        }
        return nil
    }

    // MARK: - Поток

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        if let s = await state.streams[match.trackId], s.expiresAt > Date().addingTimeInterval(60) { return s }
        var json = await state.tracks[match.trackId]
        if json == nil {
            json = try await withClientId { cid in
                try await self.get("https://api-v2.soundcloud.com/tracks/\(match.trackId)?client_id=\(cid)").flatMap { JSON.object($0) }
            }
            if let j = json { await state.cache(match.trackId, j) }
        }
        guard let j = json, let s = try await resolveStream(j) else { return nil }
        await state.cacheStream(match.trackId, s)
        return s
    }

    private func resolveStream(_ track: JSONObject) async throws -> AudioStream? {
        let transcodings = track.obj("media")?.objects("transcodings") ?? []
        let auth = track.str("track_authorization").flatMap { $0.isEmpty ? nil : $0 }
        var options: [(Int, JSONObject, String)] = []
        for t in transcodings where t.bool("snipped") != true {
            guard let f = t.obj("format") else { continue }
            let proto = f.str("protocol") ?? ""
            let mime = (f.str("mime_type") ?? "").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
            // "*-encrypted-hls" — DRM, не годится. Ogg/Opus AVFoundation не играет (PLATFORMS).
            let rank: Int
            if proto == "hls" && mime == "audio/mp4" { rank = 0 }
            else if proto == "progressive" && mime == "audio/mpeg" { rank = 1 }
            else if proto == "hls" && mime == "audio/mpeg" { rank = 2 }
            else { continue }
            options.append((rank, t, mime))
        }
        options.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            return ((a.1.str("preset") ?? "").contains("96") ? 1 : 0) < ((b.1.str("preset") ?? "").contains("96") ? 1 : 0)
        }
        for (_, t, mime) in options {
            guard let url = t.str("url"), !url.isEmpty else { continue }
            let isHls = t.obj("format")?.str("protocol") == "hls"
            let streamUrl: String? = try await withClientId { cid in
                var params = [("client_id", cid)]
                if let a = auth { params.append(("track_authorization", a)) }
                guard let body = try await self.get(self.query(url, params)), let o = JSON.object(body),
                      let u = o.str("url"), !u.isEmpty else { return nil }
                return u
            }
            guard let s = streamUrl, let u = URL(string: s) else { continue }
            let bitrate = mime == "audio/mpeg" ? 128_000 : (s.contains("96k") ? 96_000 : 160_000)
            return AudioStream(url: u, mimeType: mime, codecs: mime == "audio/mpeg" ? "mp3" : "mp4a.40.2", bitrate: bitrate,
                               // Подписанные адреса CDN живут недолго: через ~20 минут берём заново.
                               expiresAt: Date().addingTimeInterval(20 * 60), isHLS: isHls)
        }
        return nil
    }
}
