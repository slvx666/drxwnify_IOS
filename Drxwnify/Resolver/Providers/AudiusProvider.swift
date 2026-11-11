import Foundation

/// Audius как источник звука — перенос `resolver/providers/AudiusAudioProvider.kt`. Открытый API, MP3.
final class AudiusProvider: AudioProvider {
    let id = AudioProviderId.AUDIUS
    let searchTimeout: TimeInterval = 7

    private static let appName = "Drxwnify"
    private static let hostTTL: TimeInterval = 30 * 60
    private static let ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    private let state = State()

    private actor State {
        var host: (String, Date)?
        func set(_ h: String) { host = (h, Date()) }
        func current() -> String? {
            guard let h = host, Date().timeIntervalSince(h.1) < AudiusProvider.hostTTL else { return nil }
            return h.0
        }
    }

    private struct Failure: Error {
        let message: String
    }

    /// Узел обнаружения: список берётся с api.audius.co, выбирается случайный.
    private func discoveryHost(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let h = await state.current() { return h }
        let r = try await HTTP.get(URL(string: "https://api.audius.co")!, headers: ["User-Agent": Self.ua], timeout: 6)
        guard r.isSuccess, let hosts = JSON.object(r.data)?.arr("data") as? [String],
              let picked = hosts.filter({ $0.hasPrefix("https://") }).randomElement() else {
            throw Failure(message: "No Audius discovery node")
        }
        await state.set(picked)
        return picked
    }

    private func searchOn(_ host: String, _ text: String, limit: Int) async throws -> [JSONObject] {
        var c = URLComponents(string: host + "/v1/tracks/search")
        c?.queryItems = [URLQueryItem(name: "query", value: text), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
                         URLQueryItem(name: "app_name", value: Self.appName)]
        guard let url = c?.url else { throw Failure(message: "bad url") }
        let r = try await HTTP.get(url, headers: ["User-Agent": Self.ua], timeout: 6)
        guard r.isSuccess, let root = JSON.object(r.data) else { throw Failure(message: "Audius search HTTP \(r.status)") }
        return root.objects("data").filter { $0.bool("is_streamable") != false && $0.bool("is_delete") != true }
    }

    private func streamableTracks(_ text: String, limit: Int = 20) async throws -> [JSONObject] {
        do {
            return try await searchOn(try await discoveryHost(), text, limit: limit)
        } catch {
            return try await searchOn(try await discoveryHost(forceRefresh: true), text, limit: limit)
        }
    }

    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        let text = q.searchText
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let tracks = try await streamableTracks(text)
        let candidates = tracks.map { t -> FuzzyTrackMatch.Candidate in
            let d = t.int("duration") ?? 0
            return FuzzyTrackMatch.Candidate(id: t.str("id") ?? "", title: t.str("title") ?? "",
                                             artists: [t.obj("user")?.str("name") ?? ""], durationSec: d > 0 ? d : nil)
        }
        let ranked = FuzzyTrackMatch.ranked(artist: q.artists.joined(separator: ", "), title: q.title,
                                            durationSec: q.durationMs > 0 ? q.durationMs / 1000 : nil, candidates: candidates,
                                            maxDurationGap: YouTubeProvider.uploadDurationTolerance)
        guard let chosen = ranked.first(where: { !q.excludedTrackIds.contains($0.id) }),
              let track = tracks.first(where: { $0.str("id") == chosen.id }) else { return nil }
        return ProviderMatch(provider: id, trackId: chosen.id, title: track.str("title") ?? "",
                             artist: track.obj("user")?.str("name") ?? "", durationMs: (track.int("duration") ?? 0) * 1000,
                             confidence: min(chosen.score, 1.0), thumbnailUrl: track.obj("artwork")?.str("480x480"), qualityKbps: nil)
    }

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        let host = try await discoveryHost()
        guard let url = URL(string: "\(host)/v1/tracks/\(match.trackId)/stream?app_name=\(Self.appName)") else { return nil }
        guard let r = try? await HTTP.get(url, headers: ["User-Agent": Self.ua, "Range": "bytes=0-1"], timeout: 3), r.isSuccess else { return nil }
        return AudioStream(url: url, mimeType: "audio/mpeg", codecs: "mp3", bitrate: 0,
                           expiresAt: Date().addingTimeInterval(Self.hostTTL), headers: ["User-Agent": Self.ua])
    }
}
