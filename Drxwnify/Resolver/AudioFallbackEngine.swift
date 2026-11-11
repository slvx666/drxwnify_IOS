import Foundation
import GRDB

struct ResolvedAudio {
    var match: ProviderMatch
    var stream: AudioStream
    /// Играет скачанный файл.
    var isLocal = false
}

enum AudioResolveError: Error, LocalizedError {
    case notFound
    case noSources

    var errorDescription: String? {
        switch self {
        case .notFound: return L("ios_audio_not_found")
        case .noSources: return L("ios_audio_no_sources")
        }
    }
}

/// Поиск звука для трека каталога (CRITICAL §2.4, §2.6) — перенос `resolver/AudioFallbackEngine.kt`.
final class AudioFallbackEngine {
    static let manualConfidence = 10.0
    static let selectionTTL: TimeInterval = 3 * 24 * 3600
    static let missTTL: TimeInterval = 90
    static let unansweredTTL: TimeInterval = 30 * 60
    static let failedUploadTTL: TimeInterval = 3600
    static let maxOtherArtists = 2
    private static let artistSeparator = "\u{1F}"

    private let database: AppDatabase
    private let settings: TypedStore
    private let all: [AudioProvider]
    private let state = State()

    private actor State {
        var memory: [String: [ProviderMatch]] = [:]
        var misses: [String: Date] = [:]
        var failed: [String: Date] = [:]
        var slow: [AudioProviderId: Date] = [:]

        func remember(_ key: String, _ m: [ProviderMatch]) {
            if memory.count > 500 { memory.removeAll() }
            memory[key] = m
        }
        func forget(_ key: String) { memory[key] = nil }
        func miss(_ key: String, ttl: TimeInterval) { misses[key] = Date().addingTimeInterval(ttl) }
        func isMiss(_ key: String) -> Bool { (misses[key] ?? .distantPast) > Date() }
        func markFailed(_ m: ProviderMatch) { failed["\(m.provider.rawValue):\(m.trackId)"] = Date() }
        func isFailed(_ m: ProviderMatch) -> Bool {
            guard let t = failed["\(m.provider.rawValue):\(m.trackId)"] else { return false }
            return Date().timeIntervalSince(t) < AudioFallbackEngine.failedUploadTTL
        }
        func markSlow(_ id: AudioProviderId) { slow[id] = Date() }
        func slowSet() -> Set<AudioProviderId> {
            Set(slow.filter { Date().timeIntervalSince($0.value) < 600 }.keys)
        }
    }

    init(database: AppDatabase, settings: TypedStore, providers: [AudioProvider]) {
        self.database = database
        self.settings = settings
        self.all = providers
    }

    // MARK: - Настройки

    var mode: SourcePickMode {
        SourcePickMode(rawValue: settings.get(PK.sourcePickMode) ?? "") ?? .AUTO
    }

    var order: [AudioProviderId] { AudioProviderId.parseOrder(settings.get(PK.audioSourceOrder)) }

    func isEnabled(_ id: AudioProviderId) -> Bool {
        // Источник, отключённый проектом удалённо (`disabledSources`).
        if RemoteConfig.shared.config.disabledSources.contains(id.rawValue) { return false }
        switch id {
        case .SOUNDCLOUD: return settings.get(PK.audioSourceSoundCloud) ?? true
        case .YOUTUBE: return settings.get(PK.audioSourceYouTube) ?? true
        case .VK: return settings.get(PK.audioSourceVk) ?? true
        case .BANDCAMP: return settings.get(PK.audioSourceBandcamp) ?? true
        case .AUDIUS: return settings.get(PK.audioSourceAudius) ?? true
        case .LOSSLESS: return settings.get(PK.audioSourceLossless) ?? true
        case .SOULSEEK: return settings.get(PK.audioSourceSoulseek) ?? false
        }
    }

    /// Активные = порядок пользователя ∩ включённые ∩ готовые.
    private func active(excluding: Set<AudioProviderId> = []) -> [AudioProvider] {
        order.compactMap { id in
            guard isEnabled(id), !excluding.contains(id) else { return nil }
            return all.first { $0.id == id && $0.isReady() }
        }
    }

    private func provider(_ id: AudioProviderId) -> AudioProvider? { all.first { $0.id == id } }

    private func usable(_ m: ProviderMatch, _ q: AudioQuery, excluding: Set<AudioProviderId>) async -> Bool {
        if excluding.contains(m.provider) || q.excludedTrackIds.contains(m.trackId) || !isEnabled(m.provider) { return false }
        if provider(m.provider) == nil { return false }
        return !(await state.isFailed(m))
    }

    // MARK: - БД (`audio_fallback_match`)

    private struct Stored {
        var match: ProviderMatch
        var selected: Bool
        var matchedAt: Date
    }

    private func load(_ key: String) -> [Stored] {
        (try? database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM audio_fallback_match WHERE catalogId = ?", arguments: [key]).compactMap { r -> Stored? in
                guard let p = AudioProviderId(rawValue: r["provider"] as String) else { return nil }
                let ms: Int64 = r["matchedAt"]
                return Stored(match: ProviderMatch(provider: p, trackId: r["providerTrackId"], title: r["matchedTitle"],
                                                   artist: r["matchedArtist"], durationMs: nil, confidence: r["confidence"],
                                                   thumbnailUrl: nil, qualityKbps: nil),
                              selected: (r["selected"] as Int) != 0, matchedAt: Date(timeIntervalSince1970: Double(ms) / 1000))
            }
        }) ?? []
    }

    private func save(_ q: AudioQuery, matches: [ProviderMatch], selected: ProviderMatch?, keepManual: Bool = true) {
        guard !matches.isEmpty else { return }
        let key = q.cacheKey
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? database.pool.write { db in
            for m in matches {
                let isSel = selected.map { $0.provider == m.provider && $0.trackId == m.trackId } ?? false
                if isSel { try db.execute(sql: "UPDATE audio_fallback_match SET selected = 0 WHERE catalogId = ?", arguments: [key]) }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO audio_fallback_match
                    (catalogId, provider, providerTrackId, matchedTitle, matchedArtist, confidence, title, artists, album, durationMs, isrc, selected, matchedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [key, m.provider.rawValue, m.trackId, m.title, m.artist, m.confidence, q.title,
                                     q.artists.joined(separator: Self.artistSeparator), q.album, q.durationMs, q.isrc, isSel ? 1 : 0, now])
            }
        }
    }

    /// Все версии трека во всех включённых источниках (экран «Выбрать источник звука»); каждый источник ждётся до своего таймаута.
    func allVersions(_ q: AudioQuery) async -> [ProviderMatch] {
        let providers = active()
        var found: [ProviderMatch] = []
        await withTaskGroup(of: [ProviderMatch].self) { group in
            for p in providers {
                group.addTask {
                    await withTaskGroup(of: [ProviderMatch]?.self) { inner in
                        inner.addTask {
                            if let vk = p as? VkProvider { return (try? await vk.uploads(q, limit: 5)) ?? [] }
                            return ((try? await p.search(q)) ?? nil).map { [$0] } ?? []
                        }
                        inner.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(p.searchTimeout * 1_000_000_000))
                            return nil
                        }
                        let first = await inner.next() ?? nil
                        inner.cancelAll()
                        return first ?? []
                    }
                }
            }
            for await list in group { found.append(contentsOf: list) }
        }
        return ParallelAudioResolver.sorted(found, order: order, mode: .QUALITY)
    }

    /// Сбрасывает ручной выбор: дальше источник снова выбирается автоматически.
    func clearManualSelection(_ q: AudioQuery) async {
        let key = q.cacheKey
        _ = try? await database.pool.write { try $0.execute(sql: "DELETE FROM audio_fallback_match WHERE catalogId = ?", arguments: [key]) }
        await state.forget(key)
    }

    /// Выбран ли источник для трека вручную.
    func manualSelection(_ q: AudioQuery) -> ProviderMatch? {
        load(q.cacheKey).first { $0.match.confidence >= Self.manualConfidence }?.match
    }

    /// Ручной выбор версии: возвращается всегда, без срока.
    func selectManually(_ q: AudioQuery, _ m: ProviderMatch) async {
        var manual = m
        manual.confidence = Self.manualConfidence
        save(q, matches: [manual], selected: manual)
        await state.remember(q.cacheKey, [manual])
    }

    // MARK: - Поиск

    /// Кандидаты для трека, лучший первым. Пусто — нигде нет.
    func resolve(_ q: AudioQuery, forceRace: Bool = false, excluding: Set<AudioProviderId> = []) async -> [ProviderMatch] {
        let key = q.cacheKey
        // 1. Память.
        if !forceRace, let mem = await state.memory[key] {
            var ok: [ProviderMatch] = []
            for m in mem { if await usable(m, q, excluding: excluding) { ok.append(m) } }
            if !ok.isEmpty { return ok }
        }
        // 2–3. Ручной выбор и свежий автоматический из БД.
        let stored = load(key)
        if let manual = stored.first(where: { $0.match.confidence >= Self.manualConfidence }),
           await usable(manual.match, q, excluding: excluding) {
            await state.remember(key, [manual.match])
            return [manual.match]
        }
        if !forceRace, let sel = stored.first(where: { $0.selected }), Date().timeIntervalSince(sel.matchedAt) < Self.selectionTTL {
            let sorted = ParallelAudioResolver.sorted(stored.map { $0.match }, order: order, mode: mode)
            var ok: [ProviderMatch] = []
            for m in sorted { if await usable(m, q, excluding: excluding) { ok.append(m) } }
            if !ok.isEmpty {
                await state.remember(key, ok)
                return ok
            }
        }
        // 4. Отрицательный кэш: ключ включает исключения и порядок.
        let missKey = key + "|" + excluding.map { $0.rawValue }.sorted().joined(separator: ",") + "|"
            + q.excludedTrackIds.sorted().joined(separator: ",") + "|" + order.map { $0.rawValue }.joined(separator: ",")
        if !forceRace, await state.isMiss(missKey) { return [] }

        // 5. Гонка по всем активным, кроме Soulseek.
        let regular = active(excluding: excluding).filter { $0.id != .SOULSEEK }
        var result = await race(q, regular)
        // 6. Повтор под 2-м и 3-м артистом коллаборации.
        if result.winner == nil && q.artists.count > 1 {
            for other in q.artists.dropFirst().prefix(Self.maxOtherArtists) {
                var alt = q
                alt.artists = [other] + q.artists.filter { $0 != other }
                let r = await race(alt, regular)
                if r.winner != nil {
                    result = r
                    break
                }
            }
        }
        // 7. Последний резерв — Soulseek.
        if result.winner == nil {
            let last = active(excluding: excluding).filter { $0.id == .SOULSEEK }
            if !last.isEmpty { result = await race(q, last) }
        }
        guard let winner = result.winner else {
            // 8. Не найдено.
            let alive = result.allMissed ? await Self.networkAlive() : false
            await state.miss(missKey, ttl: (result.allMissed && alive) ? Self.missTTL : 5)
            var alt: [ProviderMatch] = []
            for s in stored { if await usable(s.match, q, excluding: excluding) { alt.append(s.match) } }
            return alt
        }
        // 9. Найдено: память + БД.
        let ordered = [winner] + result.matches.filter { !($0.provider == winner.provider && $0.trackId == winner.trackId) }
        await state.remember(key, ordered)
        save(q, matches: ordered, selected: winner)
        return ordered
    }

    private func race(_ q: AudioQuery, _ providers: [AudioProvider]) async -> RaceResult {
        guard !providers.isEmpty else { return RaceResult(winner: nil, matches: [], answers: [:]) }
        let slow = await state.slowSet()
        return await ParallelAudioResolver.resolve(query: q, providers: providers, mode: mode, slow: slow) { [weak self] late, answers in
            guard let self = self else { return }
            // Поздние ответы: сохраняются как версии для следующего раза; молчавшие помечаются медленными.
            self.save(q, matches: late, selected: nil)
            Task {
                for p in providers where answers[p.id] == nil { await self.state.markSlow(p.id) }
                if !late.isEmpty { await self.state.forget(q.cacheKey) }
            }
        }
    }

    private static func networkAlive() async -> Bool {
        for s in ["https://www.gstatic.com/generate_204", "https://ya.ru/"] {
            if let u = URL(string: s), let r = try? await HTTP.get(u, timeout: 4), r.status > 0 { return true }
        }
        return false
    }

    // MARK: - Поток

    /// Поток для трека: известные совпадения по очереди, затем новая гонка без уже упавших.
    func stream(for q: AudioQuery) async throws -> ResolvedAudio {
        if active().isEmpty { throw AudioResolveError.noSources }
        var tried = Set<String>()
        for attempt in 0..<2 {
            let candidates = await resolve(q, forceRace: attempt > 0)
            for m in candidates {
                let id = "\(m.provider.rawValue):\(m.trackId)"
                if tried.contains(id) { continue }
                tried.insert(id)
                try Task.checkCancellation()
                if let p = provider(m.provider), let s = try? await p.stream(q, match: m) {
                    return ResolvedAudio(match: m, stream: s)
                }
                await state.markFailed(m)
            }
            await state.forget(q.cacheKey)
        }
        throw AudioResolveError.notFound
    }

    /// Поток упал при воспроизведении: пометить, чтобы следующий `stream(for:)` взял другую версию.
    func reportBroken(_ q: AudioQuery, _ m: ProviderMatch) async {
        await state.markFailed(m)
        await state.forget(q.cacheKey)
    }
}
