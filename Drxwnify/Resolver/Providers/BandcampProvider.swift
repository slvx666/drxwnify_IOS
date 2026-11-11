import Foundation

/// Bandcamp как источник звука — перенос `resolver/providers/BandcampAudioProvider.kt`. Открытый поток MP3 128 kbps.
final class BandcampProvider: AudioProvider {
    let id = AudioProviderId.BANDCAMP
    let searchTimeout: TimeInterval = 8

    private static let pageTTL: TimeInterval = 30 * 60
    /// Длина загрузки должна быть практически той же (как `ProviderGate.UPLOAD_DURATION_TOLERANCE_S`).
    private static let durationTolerance = 8
    private static let ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let tralbum = try! NSRegularExpression(pattern: "data-tralbum=\"([^\"]+)\"")

    private struct TrackPage {
        var streamUrl: String?
        var durationSec: Int?
        var title: String
        var artist: String
    }

    private struct Found {
        var url: String
        var title: String
        var artist: String
        var thumb: String?
    }

    private let state = State()

    private actor State {
        var pages: [String: (TrackPage, Date)] = [:]
        func put(_ url: String, _ p: TrackPage) { pages[url] = (p, Date()) }
        func get(_ url: String) -> TrackPage? {
            guard let p = pages[url], Date().timeIntervalSince(p.1) < BandcampProvider.pageTTL else { return nil }
            return p.0
        }
    }

    static func unescapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func autocomplete(_ text: String) async throws -> [Found] {
        var request = URLRequest(url: URL(string: "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 7
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSON.data(["search_text": text, "search_filter": "t", "full_page": false, "fan_id": NSNull()] as [String: Any])
        let r = try await HTTP.send(request)
        guard r.isSuccess else { throw URLError(.badServerResponse) }
        let results = JSON.object(r.data)?.obj("auto")?.objects("results") ?? []
        return results.compactMap { o in
            guard o.str("type") == "t", let url = o.str("item_url_path"), url.hasPrefix("http") else { return nil }
            let img = o.str("img")
            return Found(url: url, title: o.str("name") ?? "", artist: o.str("band_name") ?? "", thumb: (img?.isEmpty == false) ? img : nil)
        }
    }

    private func loadPage(_ url: String) async -> TrackPage? {
        guard let u = URL(string: url), let r = try? await HTTP.get(u, headers: ["User-Agent": Self.ua], timeout: 7), r.isSuccess else { return nil }
        let html = r.text
        guard let m = Self.tralbum.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(m.range(at: 1), in: html),
              let json = JSON.object(Self.unescapeHtml(String(html[range]))),
              let track = json.objects("trackinfo").first else { return nil }
        let mp3 = track.obj("file")?.str("mp3-128")
        let d = Int(track.double("duration") ?? 0)
        let page = TrackPage(streamUrl: (mp3?.hasPrefix("http") == true) ? mp3 : nil, durationSec: d > 0 ? d : nil,
                             title: track.str("title") ?? "", artist: json.str("artist") ?? "")
        await state.put(url, page)
        return page
    }

    func search(_ q: AudioQuery) async throws -> ProviderMatch? {
        let text = q.searchText
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let found = try await autocomplete(text)
        // Длины в результатах поиска нет: она проверяется на странице трека.
        let ranked = FuzzyTrackMatch.ranked(
            artist: q.artists.joined(separator: ", "), title: q.title, durationSec: nil,
            candidates: found.map { FuzzyTrackMatch.Candidate(id: $0.url, title: $0.title, artists: [$0.artist], durationSec: nil) })
        let wanted = q.durationMs / 1000
        for chosen in ranked.prefix(3) where !q.excludedTrackIds.contains(chosen.id) {
            guard let page = await loadPage(chosen.id), page.streamUrl != nil else { continue }
            if wanted > 0, let d = page.durationSec, abs(d - wanted) > Self.durationTolerance { continue }
            return ProviderMatch(provider: id, trackId: chosen.id, title: page.title, artist: page.artist,
                                 durationMs: page.durationSec.map { $0 * 1000 }, confidence: min(chosen.score, 1.0),
                                 thumbnailUrl: found.first { $0.url == chosen.id }?.thumb, qualityKbps: nil)
        }
        return nil
    }

    func stream(_ q: AudioQuery, match: ProviderMatch) async throws -> AudioStream? {
        var page = await state.get(match.trackId)
        if page == nil { page = await loadPage(match.trackId) }
        guard let s = page?.streamUrl, let url = URL(string: s) else { return nil }
        return AudioStream(url: url, mimeType: "audio/mpeg", codecs: "mp3", bitrate: 128_000,
                           expiresAt: Date().addingTimeInterval(Self.pageTTL))
    }
}
