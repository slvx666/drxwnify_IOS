import Foundation

/// Лайки в другом каталоге (Android 2.3.0 `CrossCatalog.trackFor`): трек из Spotify лайкается в Яндексе или ВК
/// тем же треком, найденным по названию, исполнителю и длительности. Найденное (и «нет там») запоминается на телефоне.
enum CrossCatalog {
    private static let defaults = UserDefaults(suiteName: "drx.cross_catalog") ?? .standard
    private static let none = ""

    /// Id трека для лайка в аккаунте `target`: свой — как есть, чужой — тот же трек в каталоге `target`, nil — нет.
    static func trackFor(_ target: CatalogSource, track: Track, api: SpotifyAPI) async -> String? {
        guard let id = track.catalogId, !id.isEmpty else { return nil }
        if CatalogSource.of(id) == target { return id }
        guard MainAccount.shared.isLinked(target) else { return nil }
        let key = "t:\(target.rawValue):\(id)"
        if let known = defaults.string(forKey: key) { return known.isEmpty ? nil : known }
        let artist = track.artists.first?.name ?? ""
        let q = [artist, track.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let r = try? await api.searchIn(target, q, limit: 10) else { return nil }
        let ranked = FuzzyTrackMatch.ranked(
            artist: artist.isEmpty ? nil : artist, title: track.title,
            durationSec: track.durationMs > 0 ? track.durationMs / 1000 : nil,
            candidates: r.tracks.map { FuzzyTrackMatch.Candidate(id: $0.id, title: $0.name, artists: $0.artists.map { $0.name },
                                                                  durationSec: $0.durationMs > 0 ? $0.durationMs / 1000 : nil) })
        let match = ranked.first?.id
        defaults.set(match ?? none, forKey: key)
        return match
    }

    /// Куда уходит лайк трека по настройке «Куда уходит лайк».
    static func targets(for catalogId: String) -> [CatalogSource] {
        let m = MainAccount.shared
        let origin = CatalogSource.of(catalogId)
        let originOk = m.isLinked(origin) ? origin : nil
        var list: [CatalogSource]
        switch m.likeMode {
        case .MAIN_ONLY: list = [m.main].compactMap { $0 }
        case .MAIN_AND_SOURCE: list = [m.main, originOk].compactMap { $0 }
        case .ALL: list = m.linked
        }
        var seen = Set<CatalogSource>()
        return list.filter { seen.insert($0).inserted }
    }
}
