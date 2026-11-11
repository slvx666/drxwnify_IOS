import Foundation

func testResolver() {
    section("FuzzyTrackMatch (CRITICAL §2.3)")
    typealias C = FuzzyTrackMatch.Candidate
    expect(FuzzyTrackMatch.normalize("The Ёлка’s  Café!") == "елкаs cafe", "normalize: the, ё, апостроф, диакритика")
    expect(FuzzyTrackMatch.similarity("Blinding Lights", "blinding lights") == 1.0, "similarity: равные")
    expect(FuzzyTrackMatch.similarity("the world we saved", "the world we saved 2025 version") >= 0.9, "similarity: вхождение целым словом")
    expect(FuzzyTrackMatch.featuredArtists("Song (feat. A & B)") == ["A", "B"], "гости из названия")
    expect(FuzzyTrackMatch.titleVariants("07 - Song (Remastered) - 2011 Remaster").contains("Song"), "варианты названия")

    let exact = FuzzyTrackMatch.best(artist: "Daft Punk", title: "Get Lucky", durationSec: 248,
                                     candidates: [C(id: "a", title: "Get Lucky", artists: ["Daft Punk"], durationSec: 249)])
    expect(exact != nil && abs((exact?.score ?? 0) - 1.05) < 0.0001, "точное совпадение: 0.6 + 0.4 + 0.05")
    expect(FuzzyTrackMatch.best(artist: "Daft Punk", title: "Get Lucky", durationSec: 248,
                                candidates: [C(id: "a", title: "Get Lucky (Remix)", artists: ["Daft Punk"], durationSec: 248)]) == nil,
           "чужой маркер remix отбрасывается")
    expect(FuzzyTrackMatch.best(artist: "Daft Punk", title: "Get Lucky", durationSec: 248,
                                candidates: [C(id: "a", title: "Get Lucky", artists: ["Daft Punk"], durationSec: 290)]) == nil,
           "длина отличается больше чем на 30 с")
    expect(FuzzyTrackMatch.best(artist: "Daft Punk", title: "Get Lucky", durationSec: 248,
                                candidates: [C(id: "a", title: "Get Lucky", artists: ["Someone Else"], durationSec: 248)]) == nil,
           "другой артист")
    expect(FuzzyTrackMatch.best(artist: nil, title: "Get Lucky", durationSec: 248,
                                candidates: [C(id: "a", title: "Get Lucky", artists: [], durationSec: 250)]) != nil,
           "без артиста: название ≥ 0.97 и близкая длина")

    section("Гонка источников (CRITICAL §2.5)")
    func m(_ p: AudioProviderId, _ c: Double, kbps: Int? = nil) -> ProviderMatch {
        ProviderMatch(provider: p, trackId: p.rawValue, title: "", artist: "", durationMs: nil, confidence: c, thumbnailUrl: nil, qualityKbps: kbps)
    }
    let order = AudioProviderId.defaultOrder
    expect(AudioProviderId.parseOrder("VK,NOPE,YOUTUBE").prefix(3) == [.VK, .YOUTUBE, .SOUNDCLOUD], "порядок: неизвестные прочь, остальные в конец")
    expect(ParallelAudioResolver.preferred([m(.VK, 0.95), m(.SOUNDCLOUD, 0.9), m(.AUDIUS, 0.6)], order: order).map { $0.provider }
           == [.SOUNDCLOUD, .VK, .AUDIUS], "SPEED: в пределах 0.15 — по порядку пользователя")
    expect(ParallelAudioResolver.byQuality([m(.SOUNDCLOUD, 0.99), m(.VK, 0.97), m(.LOSSLESS, 0.8)], order: order, margin: 0.05).map { $0.provider }
           == [.VK, .SOUNDCLOUD, .LOSSLESS], "AUTO: в пределах 0.05 — по битрейту")

    func take(_ d: ParallelAudioResolver.Decision) -> AudioProviderId? {
        if case .take(let w) = d { return w?.provider }
        return nil
    }
    func waits(_ d: ParallelAudioResolver.Decision) -> Bool {
        if case .wait = d { return true }
        return false
    }
    typealias R = ParallelAudioResolver
    expect(take(R.decide(matches: [m(.VK, 0.99)], searching: [], slow: [], order: order, mode: .SPEED, elapsed: 0.1)) == .VK, "никто не ищет — лучший")
    expect(waits(R.decide(matches: [m(.VK, 0.99)], searching: [.SOUNDCLOUD], slow: [], order: order, mode: .SPEED, elapsed: 0.1)),
           "SPEED: ждать источник выше рангом")
    expect(take(R.decide(matches: [m(.VK, 0.99)], searching: [.SOUNDCLOUD], slow: [], order: order, mode: .SPEED, elapsed: 2.6)) == .VK,
           "SPEED: после 2.5 с брать уверенное")
    expect(take(R.decide(matches: [m(.SOUNDCLOUD, 0.99)], searching: [.VK], slow: [], order: order, mode: .AUTO, elapsed: 0.1)) == .SOUNDCLOUD,
           "AUTO: ≥0.95 и ≥120 kbps — брать сразу")
    expect(waits(R.decide(matches: [m(.SOUNDCLOUD, 0.99)], searching: [.VK], slow: [], order: order, mode: .QUALITY, elapsed: 0.1)),
           "QUALITY: ждать источник с лучшим битрейтом")
    expect(take(R.decide(matches: [m(.SOUNDCLOUD, 0.99)], searching: [.VK], slow: [], order: order, mode: .QUALITY, elapsed: 5.1)) == .SOUNDCLOUD,
           "QUALITY: через 5 с брать")
    expect(take(R.decide(matches: [m(.VK, 0.99)], searching: [.AUDIUS], slow: [], order: order, mode: .QUALITY, elapsed: 0.1)) == .VK,
           "QUALITY: ≥256 kbps и лучше никто не даст")
    expect(waits(R.decide(matches: [], searching: [.VK], slow: [], order: order, mode: .AUTO, elapsed: 13)), "без совпадений ждать до 14 с")
    if case .take(let w) = R.decide(matches: [], searching: [.VK], slow: [], order: order, mode: .AUTO, elapsed: 14.1) {
        expect(w == nil, "без совпадений после 14 с — пусто")
    } else {
        expect(false, "без совпадений после 14 с — пусто")
    }

    section("Ссылки приложения (CRITICAL §4.4)")
    expect(AppLinks.link(.track, id: "abc", title: "Get Lucky", by: "Daft Punk") == "https://drxwnify.pages.dev/track/abc?n=Get%20Lucky&by=Daft%20Punk", "ссылка на трек")
    expect(AppLinks.trackLink(mediaId: "mfb:abc", title: "T", by: "A") == "A — T\nhttps://drxwnify.pages.dev/track/abc?n=T&by=A", "текст «поделиться»")
    expect(AppLinks.trackLink(mediaId: "dQw4", title: nil, by: nil) == "https://drxwnify.pages.dev/track/yt%3AdQw4", "видео YouTube")
    expect(AppLinks.parse(URL(string: "https://open.spotify.com/intl-de/album/XYZ?si=1")!) == AppLinks.Target(kind: .album, id: "XYZ", title: nil, by: nil), "ссылка Spotify с intl-")
    expect(AppLinks.parse(URL(string: "drxwnify://artist/A1")!)?.id == "A1", "схема drxwnify://")
    expect(AppLinks.parse(URL(string: "https://drxwnify.pages.dev/playlist/P?n=My%20List")!)?.title == "My List", "название из ссылки")
    expect(AppLinks.parse(URL(string: "https://example.com/album/1")!) == nil, "чужой хост")
}
