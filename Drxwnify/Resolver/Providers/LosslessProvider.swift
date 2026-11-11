import Foundation

/// FLAC с публичных зеркал «hifi-api» — перенос `resolver/providers/LosslessMirrorProvider.kt`.
/// Список зеркал приходит из `RemoteConfig`; без зеркал источник простаивает.
/// Ответы читаются с запасом: поиск кладёт `items` в разные места, трек отдаёт base64-`manifest` с `urls` или `OriginalTrackUrl`.
final class LosslessProvider: AudioProvider {
    let id = AudioProviderId.LOSSLESS
    let searchTimeout: TimeInterval = 9

    private let state = State()

    private actor State {
        var lastGood: String?
        var durations: [String: Int] = [:]
        func good(_ base: String) { lastGood = base }
        func setDuration(_ id: String, _ d: Int) { durations[id] = d }
    }

    func isReady() -> Bool { !RemoteConfig.shared.config.losslessMirrors.isEmpty }

    /// GET на первом зеркале, которое ответило JSON; последнее рабочее пробуется первым.
    private func get(_ path: String, _ params: [(String, String)]) async -> Any? {
        let all = RemoteConfig.shared.config.losslessMirrors
        let good = await state.lastGood
        let ordered = (good.map { all.contains($0) ? [$0] : [] } ?? []) + all.filter { $0 != good }
        for base in ordered {
            var c = URLComponents(string: base + path)
            c?.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
            guard let url = c?.url, let r = try? await HTTP.get(url, timeout: 8), r.isSuccess,
                  let json = try? JSONSerialization.jsonObject(with: r.data), json is JSONObject || json is [Any] else { continue }
            await state.good(base)
            return json
        }
        return nil
    }

    /// Массив `items`, где бы его ни положила эта версия сервера (`items`, `data.items`, `tracks.items`, `[ {items} ]`).
    private func findItems(_ root: Any) -> [JSONObject] {
        func from(_ o: JSONObject) -> [Any]? {
            if let a = o.arr("items") { return a }
            if let d = o.obj("data"), let a = from(d) { return a }
            if let t = o.obj("tracks"), let a = from(t) { return a }
            return nil
        }
        var array: [Any]?
        if let o = root as? JSONObject {
            array = from(o)
        } else if let list = root as? [Any] {
            for item in list {
                if let o = item as? JSONObject, let a = from(o) {
                    array = a
                    break
                }
            }
        }
        return (array ?? []).compactMap { $0 as? JSONObject }
    }

    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        guard isReady(), let root = await get("/search/", [("s", q.searchText)]) else { return nil }
        var parsed: [(id: String, o: JSONObject, artist: String)] = []
        for o in findItems(root) {
            guard let trackId = o.str("id"), !trackId.isEmpty else { continue }
            let artist = o.obj("artist")?.str("name") ?? o.objects("artists").first?.str("name") ?? ""
            parsed.append((trackId, o, artist))
        }
        if parsed.isEmpty { return nil }
        func match(_ p: (id: String, o: JSONObject, artist: String), _ confidence: Double) async -> ProviderMatch {
            let d = p.o.int("duration") ?? 0
            await state.setDuration(p.id, d)
            return ProviderMatch(provider: id, trackId: p.id, title: p.o.str("title") ?? "", artist: p.artist,
                                 durationMs: d * 1000, confidence: confidence, thumbnailUrl: nil, qualityKbps: 1411)
        }
        // Та же запись по ISRC — наверняка; иначе обычная проверка названия, артиста и длины.
        if let isrc = q.isrc, !isrc.isEmpty,
           let exact = parsed.first(where: { ($0.o.str("isrc") ?? "").caseInsensitiveCompare(isrc) == .orderedSame }),
           !q.excludedTrackIds.contains(exact.id) {
            return await match(exact, 1.0)
        }
        let ranked = FuzzyTrackMatch.ranked(
            artist: q.artists.joined(separator: ", "), title: q.title, durationSec: q.durationMs > 0 ? q.durationMs / 1000 : nil,
            candidates: parsed.map { p in
                let d = p.o.int("duration") ?? 0
                return FuzzyTrackMatch.Candidate(id: p.id, title: p.o.str("title") ?? "", artists: [p.artist], durationSec: d > 0 ? d : nil)
            }, maxDurationGap: YouTubeProvider.uploadDurationTolerance)
        guard let chosen = ranked.first(where: { !q.excludedTrackIds.contains($0.id) }),
              let p = parsed.first(where: { $0.id == chosen.id }) else { return nil }
        return await match(p, min(chosen.score, 1.0))
    }

    /// Адрес FLAC: из base64-манифеста (`urls`) или поля `OriginalTrackUrl`.
    private func streamUrl(_ root: Any) -> (String, String)? {
        var objects: [JSONObject] = []
        if let o = root as? JSONObject {
            objects.append(o)
            if let d = o.obj("data") { objects.append(d) }
        } else if let list = root as? [Any] {
            objects = list.compactMap { $0 as? JSONObject }
        }
        for o in objects {
            if let direct = o.str("OriginalTrackUrl"), direct.hasPrefix("http") { return (direct, "audio/flac") }
            guard let manifest = o.str("manifest"), !manifest.isEmpty,
                  let data = Data(base64Encoded: manifest, options: .ignoreUnknownCharacters),
                  let json = JSON.object(data),   // DASH (xml) не разбирается
                  let url = (json.arr("urls")?.first as? String), url.hasPrefix("http") else { continue }
            let mime = json.str("mimeType") ?? ""
            return (url, mime.isEmpty ? "audio/flac" : mime)
        }
        return nil
    }

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        guard let root = await get("/track/", [("id", match.trackId), ("quality", "LOSSLESS")]),
              let (s, mime) = streamUrl(root), let url = URL(string: s) else { return nil }
        // FLAC переменный: настоящий средний битрейт — размер на длину.
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 6
        let size = (try? await HTTP.send(head)).flatMap { $0.header("Content-Length") }.flatMap { Int($0) } ?? 0
        let known = await state.durations[match.trackId] ?? 0
        let seconds = known > 0 ? known : q.durationMs / 1000
        let bitrate = (size > 0 && seconds > 0) ? size * 8 / seconds : 0
        return AudioStream(url: url, mimeType: mime, codecs: mime.contains("flac") ? "flac" : "", bitrate: bitrate,
                           expiresAt: Date().addingTimeInterval(20 * 60))
    }
}
