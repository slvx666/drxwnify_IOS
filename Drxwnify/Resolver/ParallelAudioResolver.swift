import Foundation

/// Режим выбора источника (`sourcePickMode`).
enum SourcePickMode: String {
    case SPEED, AUTO, QUALITY
}

enum ProviderAnswer {
    case found(ProviderMatch)
    case miss
    case failed
}

struct RaceResult {
    var winner: ProviderMatch?
    /// Все совпадения на момент решения, лучшее первым.
    var matches: [ProviderMatch]
    var answers: [AudioProviderId: ProviderAnswer]

    /// Все опрошенные честно ответили «нет».
    var allMissed: Bool {
        !answers.isEmpty && answers.values.allSatisfy { if case .miss = $0 { return true } else { return false } }
    }
}

/// Гонка источников (CRITICAL §2.5) — перенос `resolver/ParallelAudioResolver.kt`.
enum ParallelAudioResolver {
    static let confidenceMargin = 0.15
    static let strongMatch = 0.9
    static let autoInstantMatch = 0.95
    static let lowKbps = 120
    static let autoLowGrace = 1.2
    static let qualityTargetKbps = 256
    static let qualityTargetGrace = 1.5
    static let qualityDeadline = 5.0
    static let qualityConfidenceMargin = 0.12
    static let autoConfidenceMargin = 0.05
    static let softDeadline = 2.5
    static let hardDeadline = 14.0

    private enum Event {
        case answer(AudioProviderId, ProviderAnswer)
        case tick
    }

    // MARK: - Сортировка

    /// SPEED: в пределах 0.15 от лучшей уверенности — по порядку пользователя, остальные — по уверенности.
    static func preferred(_ matches: [ProviderMatch], order: [AudioProviderId]) -> [ProviderMatch] {
        guard let top = matches.map({ $0.confidence }).max() else { return [] }
        func rank(_ m: ProviderMatch) -> Int { order.firstIndex(of: m.provider) ?? Int.max }
        let near = matches.filter { $0.confidence >= top - confidenceMargin }.sorted { rank($0) < rank($1) }
        let rest = matches.filter { $0.confidence < top - confidenceMargin }.sorted { $0.confidence > $1.confidence }
        return near + rest
    }

    /// AUTO / QUALITY: в пределах `margin` от лучшей — по ожидаемому битрейту, затем по порядку; остальные — по уверенности.
    static func byQuality(_ matches: [ProviderMatch], order: [AudioProviderId], margin: Double) -> [ProviderMatch] {
        guard let top = matches.map({ $0.confidence }).max() else { return [] }
        func rank(_ m: ProviderMatch) -> Int { order.firstIndex(of: m.provider) ?? Int.max }
        let near = matches.filter { $0.confidence >= top - margin }.sorted {
            $0.expectedKbps != $1.expectedKbps ? $0.expectedKbps > $1.expectedKbps : rank($0) < rank($1)
        }
        let rest = matches.filter { $0.confidence < top - margin }.sorted { $0.confidence > $1.confidence }
        return near + rest
    }

    static func sorted(_ matches: [ProviderMatch], order: [AudioProviderId], mode: SourcePickMode) -> [ProviderMatch] {
        switch mode {
        case .SPEED: return preferred(matches, order: order)
        case .AUTO: return byQuality(matches, order: order, margin: autoConfidenceMargin)
        case .QUALITY: return byQuality(matches, order: order, margin: qualityConfidenceMargin)
        }
    }

    // MARK: - Решение

    enum Decision {
        case wait
        /// Победитель; nil — никто не нашёл.
        case take(ProviderMatch?)
    }

    static func decide(matches: [ProviderMatch], searching: [AudioProviderId], slow: Set<AudioProviderId>,
                       order: [AudioProviderId], mode: SourcePickMode, elapsed: Double) -> Decision {
        if searching.isEmpty { return .take(sorted(matches, order: order, mode: mode).first) }
        if matches.isEmpty { return elapsed >= hardDeadline ? .take(nil) : .wait }
        if elapsed >= hardDeadline { return .take(sorted(matches, order: order, mode: mode).first) }
        let waitable = searching.filter { !slow.contains($0) }
        func rank(_ id: AudioProviderId) -> Int { order.firstIndex(of: id) ?? Int.max }

        func speed() -> Decision {
            let best = preferred(matches, order: order)[0]
            let higher = waitable.contains { rank($0) < rank(best.provider) }
            let doubtful = best.confidence < strongMatch
            if elapsed >= softDeadline { return (doubtful && higher) ? .wait : .take(best) }
            if higher || (doubtful && !waitable.isEmpty) { return .wait }
            return .take(best)
        }

        switch mode {
        case .SPEED:
            return speed()
        case .AUTO:
            let best = byQuality(matches, order: order, margin: autoConfidenceMargin)[0]
            if best.confidence < autoInstantMatch { return speed() }
            if best.expectedKbps >= lowKbps { return .take(best) }
            if elapsed >= autoLowGrace || !waitable.contains(where: { $0.typicalKbps >= lowKbps }) { return .take(best) }
            return .wait
        case .QUALITY:
            if !matches.contains(where: { $0.confidence >= strongMatch }) { return .wait }
            let best = byQuality(matches, order: order, margin: qualityConfidenceMargin)[0]
            let betterPossible = waitable.contains { $0.typicalKbps > best.expectedKbps }
            if best.expectedKbps >= qualityTargetKbps && (!betterPossible || elapsed >= qualityTargetGrace) { return .take(best) }
            if !betterPossible || elapsed >= qualityDeadline { return .take(best) }
            return .wait
        }
    }

    // MARK: - Гонка

    /// `providers` — в порядке пользователя. `onLate` получает совпадения, пришедшие после решения (AUTO/QUALITY).
    static func resolve(query: AudioQuery, providers: [AudioProvider], mode: SourcePickMode,
                        slow: Set<AudioProviderId> = [],
                        onLate: @escaping ([ProviderMatch], [AudioProviderId: ProviderAnswer]) -> Void = { _, _ in }) async -> RaceResult {
        if providers.isEmpty { return RaceResult(winner: nil, matches: [], answers: [:]) }
        let order = providers.map { $0.id }
        var continuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event> { continuation = $0 }
        let cont = continuation!

        var tasks: [Task<Void, Never>] = []
        for p in providers {
            tasks.append(Task.detached {
                let answer = await searchWithTimeout(p, query)
                cont.yield(.answer(p.id, answer))
            })
        }
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                cont.yield(.tick)
            }
        }

        let started = Date()
        var answers: [AudioProviderId: ProviderAnswer] = [:]
        var matches: [ProviderMatch] = []
        var winner: ProviderMatch?
        var decided = false
        var iterator = stream.makeAsyncIterator()

        while !decided, let event = await iterator.next() {
            if case .answer(let id, let a) = event {
                answers[id] = a
                if case .found(let m) = a { matches.append(m) }
            }
            let searching = order.filter { answers[$0] == nil }
            if case .take(let w) = decide(matches: matches, searching: searching, slow: slow, order: order, mode: mode,
                                          elapsed: Date().timeIntervalSince(started)) {
                winner = w
                decided = true
            }
        }

        let result = RaceResult(winner: winner, matches: sorted(matches, order: order, mode: mode), answers: answers)
        let pending = order.filter { answers[$0] == nil }
        if pending.isEmpty || mode == .SPEED {
            tasks.forEach { $0.cancel() }
            ticker.cancel()
            cont.finish()
        } else {
            // Ещё ищущие заканчивают в фоне до 14 с: их находки сохраняются как версия получше.
            let knownAnswers = answers
            Task.detached {
                var it = iterator
                var late: [ProviderMatch] = []
                var all = knownAnswers
                while all.count < order.count, Date().timeIntervalSince(started) < hardDeadline, let event = await it.next() {
                    if case .answer(let id, let a) = event {
                        all[id] = a
                        if case .found(let m) = a { late.append(m) }
                    }
                }
                tasks.forEach { $0.cancel() }
                ticker.cancel()
                cont.finish()
                onLate(late, all)
            }
        }
        return result
    }

    private static func searchWithTimeout(_ p: AudioProvider, _ q: AudioQuery) async -> ProviderAnswer {
        await withTaskGroup(of: ProviderAnswer?.self) { group in
            group.addTask {
                do {
                    if let m = try await p.search(q) { return .found(m) }
                    return .miss
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(p.searchTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed
        }
    }
}
