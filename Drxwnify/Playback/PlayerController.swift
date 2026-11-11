import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// Плеер: очередь, `AVQueuePlayer`, фон, экран блокировки (PLAY-001…006, PLAY-014, PLAY-035).
/// Все изменения состояния — на главном потоке.
final class PlayerController: NSObject, ObservableObject {
    // MARK: - Состояние для интерфейса

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var queueTitle: String?
    @Published private(set) var isPlaying = false
    /// Ищется звук или идёт буферизация.
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var shuffle = false
    @Published private(set) var errorText: String?
    /// Откуда сейчас идёт звук (строка качества в плеере).
    @Published private(set) var serving: ProviderMatch?
    @Published private(set) var servingStream: AudioStream?
    @Published private(set) var servingLocal = false
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var sleepAtEndOfTrack = false
    @Published var queueLocked = false
    /// Скорость и «тон вместе со скоростью» (UI-319).
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var pitchFollowsRate = false

    /// Позиция прямо из `AVPlayer` (для пословной подсветки текста).
    var exactPosition: Double {
        guard currentItem != nil else { return position }
        let t = player.currentTime().seconds
        return t.isFinite ? t : position
    }
    var current: Track? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var hasNext: Bool { nextIndex(auto: false) != nil }

    // MARK: - Внутреннее

    private let engine: AudioFallbackEngine
    private let database: AppDatabase
    private let settings: TypedStore
    private let player = AVQueuePlayer()

    /// Порядок воспроизведения при перемешивании: перестановка индексов очереди.
    private var shuffleOrder: [Int] = []
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var preloaded: (index: Int, item: AVPlayerItem, audio: ResolvedAudio)?
    private var currentItem: AVPlayerItem?
    private var currentAudio: ResolvedAudio?
    private var retriedCurrent = false
    private var wantsPlay = false
    private var consecutiveFailures = 0
    private var resumeAfterInterruption = false
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var sleepTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var artworkTask: Task<Void, Never>?
    private var artwork: (url: String, image: UIImage)?
    /// Сколько секунд текущий трек реально играл (для истории).
    private var playedSeconds: Double = 0
    private var lastTick: Date?
    private var historyRecorded = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(engine: AudioFallbackEngine, database: AppDatabase, settings: TypedStore) {
        self.engine = engine
        self.database = database
        self.settings = settings
        super.init()
        if settings.get(PK.rememberShuffleAndRepeat) ?? true {
            repeatMode = RepeatMode(rawValue: settings.get(PK.repeatMode) ?? 0) ?? .off
            shuffle = settings.get(PK.shuffleMode) ?? false
        }
        pitchFollowsRate = settings.get(PK.varispeed) ?? false
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = settings.get(PK.playerVolume) ?? 1
        observePlayer()
        setupRemoteCommands()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        restoreQueue()
    }

    // MARK: - Очередь: запуск

    /// Откуда очередь: от этого зависит, что заиграет после неё (PLAY-007).
    enum Origin {
        /// Плейлист, лайки, история: после конца — тишина, как у плейлистов на Android.
        case list
        /// Альбом или один трек: дальше радио похожих артистов.
        case album
        /// Топ артиста: его другие песни, потом похожие; `shuffleAll` — «Перемешать» без повторов.
        case artist(String, shuffleAll: Bool)
        /// Вся дискография артиста уже в очереди: после неё — похожие исполнители.
        case artistDiscography(String)
        /// Свой источник продолжения («Для тебя»).
        case radio(RadioSource)
    }

    /// Каталог для радио (ставит `AppEnvironment`).
    var catalog: SpotifyAPI?
    /// Чем продолжается очередь; `nil` — ничем.
    private var radio: RadioSource?
    private var extending = false
    private var radioRounds = 0

    /// Заменяет очередь и начинает с `startIndex` (или со случайного трека при `shuffled`).
    /// Один трек без контекста продолжается радио, как `SpotifyQueue` на Android.
    func play(_ tracks: [Track], startIndex: Int = 0, title: String? = nil, shuffled: Bool? = nil, origin: Origin? = nil) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        queueTitle = title
        RecommendedTracks.shared.clear()
        radioRounds = 0
        extending = false
        switch origin ?? (tracks.count == 1 ? .album : .list) {
        case .list: radio = nil
        case .album: radio = catalog.map { ListRadio(original: tracks, api: $0) }
        case .artist(let id, let all): radio = catalog.map { ArtistRadio(artistId: id, shuffleAll: all, api: $0) }
        case .artistDiscography(let id): radio = catalog.map { ArtistRadio(artistId: id, shuffleAll: true, api: $0, discographyQueued: true) }
        case .radio(let source):
            radio = source
            RecommendedTracks.shared.mark(tracks)
        }
        if let s = shuffled, s != shuffle {
            shuffle = s
            settings.set(PK.shuffleMode, s)
        }
        let start = shuffled == true ? Int.random(in: 0..<tracks.count) : min(max(0, startIndex), tracks.count - 1)
        rebuildShuffle(first: start)
        load(start, autoplay: true)
    }

    func play(_ track: Track) { play([track]) }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let i = currentIndex else { return play(tracks) }
        insert(tracks, at: i + 1, afterCurrentInShuffle: true)
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentIndex != nil else { return play(tracks) }
        insert(tracks, at: queue.count, afterCurrentInShuffle: false)
    }

    private func insert(_ incoming: [Track], at index: Int, afterCurrentInShuffle: Bool) {
        var tracks = incoming
        if settings.get(PK.preventDuplicateTracksInQueue) ?? false {
            let have = Set(queue.map { $0.id })
            tracks = tracks.filter { !have.contains($0.id) }
            if tracks.isEmpty { return }
        }
        queue.insert(contentsOf: tracks, at: index)
        if let c = currentIndex, index <= c { currentIndex = c + tracks.count }
        // Сдвигаем индексы в порядке перемешивания и вставляем новые.
        shuffleOrder = shuffleOrder.map { $0 >= index ? $0 + tracks.count : $0 }
        let fresh = Array(index..<index + tracks.count)
        if afterCurrentInShuffle {
            let pos = (currentIndex.flatMap { shuffleOrder.firstIndex(of: $0) } ?? -1) + 1
            shuffleOrder.insert(contentsOf: fresh, at: pos)
        } else {
            shuffleOrder.append(contentsOf: fresh)
        }
        queueChanged()
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        load(index, autoplay: true)
    }

    func remove(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let wasCurrent = index == currentIndex
        queue.remove(at: index)
        shuffleOrder = shuffleOrder.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 }
        if queue.isEmpty { return clearQueue() }
        if let c = currentIndex {
            if index < c { currentIndex = c - 1 }
            if wasCurrent {
                load(min(index, queue.count - 1), autoplay: isPlaying)
                return
            }
        }
        queueChanged()
    }

    /// Возвращает удалённый трек на место (отмена удаления, PLAY-003).
    func restore(_ track: Track, at index: Int) {
        guard currentIndex != nil else { return play(track) }
        insert([track], at: min(index, queue.count), afterCurrentInShuffle: false)
    }

    func move(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), destination >= 0, destination <= queue.count, source != destination else { return }
        let id = current?.id
        let t = queue.remove(at: source)
        queue.insert(t, at: destination > source ? destination - 1 : destination)
        // Перестановка сбрасывает случайный порядок: проще и предсказуемо.
        if let id = id { currentIndex = queue.firstIndex { $0.id == id } }
        rebuildShuffle(first: currentIndex ?? 0)
        queueChanged()
    }

    func clearQueue() {
        recordHistoryIfNeeded()
        loadTask?.cancel()
        dropPreload()
        player.removeAllItems()
        currentItem = nil
        currentAudio = nil
        queue = []
        shuffleOrder = []
        radio = nil
        currentIndex = nil
        queueTitle = nil
        isPlaying = false
        isLoading = false
        wantsPlay = false
        position = 0
        duration = 0
        serving = nil
        servingStream = nil
        updateNowPlaying()
        scheduleSave()
    }

    private func queueChanged() {
        dropPreload()
        schedulePreload()
        scheduleSave()
        extendIfNeeded()
    }

    /// Автодогрузка (PLAY-007): за два трека до конца очередь продолжает радио. Выключается настройкой
    /// «Автодогрузка» и, если включено «не догружать при повторе всего», повтором всего.
    private func extendIfNeeded() {
        guard let radio = radio, !extending, let c = currentIndex, settings.get(PK.autoLoadMore) ?? true else { return }
        if repeatMode == .all && (settings.get(PK.disableLoadMoreWhenRepeatAll) ?? false) { return }
        let position = shuffle ? (shuffleOrder.firstIndex(of: c) ?? 0) : c
        guard queue.count - position - 1 <= 2, radioRounds < 200 else { return }
        extending = true
        radioRounds += 1
        let queued = queue
        Task { [weak self] in
            let more = await radio.more(after: queued)
            await MainActor.run {
                guard let self = self else { return }
                self.extending = false
                guard self.radio === radio else { return }
                let have = Set(self.queue.map { $0.id })
                var seenKeys = Set(self.queue.map { RecentlyPlayed.keyOf($0) })
                let fresh = more.filter { t in
                    !have.contains(t.id) && !BlockedTracks.shared.isBlocked(t) && seenKeys.insert(RecentlyPlayed.keyOf(t)).inserted
                }
                guard !fresh.isEmpty else { return }
                RecommendedTracks.shared.mark(fresh)
                self.insert(fresh, at: self.queue.count, afterCurrentInShuffle: false)
            }
        }
    }

    // MARK: - Перемешивание и повтор

    func toggleShuffle() {
        shuffle.toggle()
        settings.set(PK.shuffleMode, shuffle)
        rebuildShuffle(first: currentIndex ?? 0)
        queueChanged()
    }

    private func rebuildShuffle(first: Int) {
        guard !queue.isEmpty else {
            shuffleOrder = []
            return
        }
        var rest = Array(queue.indices).filter { $0 != first }
        rest.shuffle()
        shuffleOrder = [first] + rest
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        settings.set(PK.repeatMode, repeatMode.rawValue)
        queueChanged()
    }

    /// Следующий индекс. `auto` — переход по окончании трека (учитывает «повторять один»).
    private func nextIndex(auto: Bool) -> Int? {
        guard let c = currentIndex, !queue.isEmpty else { return nil }
        if auto && repeatMode == .one { return c }
        if shuffle {
            guard let p = shuffleOrder.firstIndex(of: c) else { return nil }
            if p + 1 < shuffleOrder.count { return shuffleOrder[p + 1] }
            return repeatMode == .all ? shuffleOrder.first : nil
        }
        if c + 1 < queue.count { return c + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func previousIndex() -> Int? {
        guard let c = currentIndex, !queue.isEmpty else { return nil }
        if shuffle {
            guard let p = shuffleOrder.firstIndex(of: c) else { return nil }
            if p > 0 { return shuffleOrder[p - 1] }
            return repeatMode == .all ? shuffleOrder.last : nil
        }
        if c > 0 { return c - 1 }
        return repeatMode == .all ? queue.count - 1 : nil
    }

    // MARK: - Управление

    func togglePlayPause() {
        if isPlaying || (wantsPlay && isLoading) { pause() } else { resume() }
    }

    func resume() {
        guard let c = currentIndex else { return }
        errorText = nil
        if currentItem == nil || currentItem?.status == .failed || (currentAudio?.stream.expiresAt ?? .distantFuture) < Date() {
            load(c, autoplay: true, startAt: position)
            return
        }
        if duration > 0 && position >= duration - 0.5 { player.seek(to: .zero) }
        wantsPlay = true
        activateSession()
        startPlayer()
    }

    func pause() {
        wantsPlay = false
        player.pause()
        if currentItem == nil {
            isLoading = false
            loadTask?.cancel()
        }
        scheduleSave()
    }

    func skipNext() {
        guard let n = nextIndex(auto: false) else { return }
        load(n, autoplay: true)
    }

    /// Как на Android: после 3 секунд — в начало трека, иначе предыдущий.
    func skipPrevious() {
        if position <= 3, let p = previousIndex() {
            load(p, autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        lastTick = nil
        guard currentItem != nil else { return scheduleSave() }
        player.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.updateNowPlaying() }
        }
    }

    /// Заново ищет звук для текущего трека с того же места (после ручной смены источника).
    func reloadCurrent() {
        guard let c = currentIndex else { return }
        load(c, autoplay: wantsPlay || isPlaying, startAt: position, isRetry: true)
    }

    var audioEngine: AudioFallbackEngine { engine }

    /// Прослушивание записано в историю (друзья получают историю).
    var onListened: (() -> Void)?

    /// Скачанный файл трека, если он есть: тогда звук в сети не ищется (офлайн).
    var localAudio: ((Track) -> ResolvedAudio?)?

    private func resolve(_ track: Track) async throws -> ResolvedAudio {
        if let local = await MainActor.run(body: { self.localAudio?(track) }) { return local }
        return try await engine.stream(for: track.audioQuery)
    }

    // MARK: - Загрузка трека

    private func load(_ index: Int, autoplay: Bool, startAt: Double = 0, isRetry: Bool = false) {
        guard queue.indices.contains(index) else { return }
        recordHistoryIfNeeded()
        loadTask?.cancel()
        let track = queue[index]
        currentIndex = index
        position = startAt
        duration = Double(track.durationMs) / 1000
        errorText = nil
        wantsPlay = autoplay
        if BlockedTracks.shared.isBlocked(track) {
            fail(L("ios_track_blocked"), index: index)
            return
        }
        retriedCurrent = isRetry
        resetPlayCounter()
        loadArtwork(track)
        scheduleSave()
        extendIfNeeded()

        // Следующий уже подготовлен — играем его без поиска.
        if let pre = preloaded, pre.index == index, startAt == 0, pre.audio.stream.expiresAt > Date().addingTimeInterval(30) {
            preloaded = nil
            preloadTask?.cancel()
            if player.items().contains(pre.item) && player.currentItem !== pre.item {
                player.advanceToNextItem()
            } else if player.currentItem !== pre.item {
                player.removeAllItems()
                player.insert(pre.item, after: nil)
            }
            adopt(pre.item, pre.audio)
            if autoplay {
                activateSession()
                startPlayer()
            }
            schedulePreload()
            return
        }

        dropPreload()
        player.pause()
        player.removeAllItems()
        currentItem = nil
        currentAudio = nil
        serving = nil
        servingStream = nil
        isLoading = true
        updateNowPlaying()
        beginBackgroundTask()
        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let audio = try await self.resolve(track)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.currentIndex == index, self.queue.indices.contains(index), self.queue[index].id == track.id else { return }
                    // Рекомендованный трек ниже 120 kbps не играет (PLAY-010): дальше следующий.
                    if !audio.isLocal, RecommendedTracks.shared.tooLow(track.id, bitrate: audio.stream.bitrate) {
                        self.endBackgroundTask()
                        self.fail(L("ios_low_quality_skipped"), index: index)
                        return
                    }
                    let item = self.makeItem(audio)
                    self.player.insert(item, after: nil)
                    self.adopt(item, audio)
                    if startAt > 0 {
                        self.player.seek(to: CMTime(seconds: startAt, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    if self.wantsPlay {
                        self.activateSession()
                        self.startPlayer()
                    }
                    self.schedulePreload()
                    self.endBackgroundTask()
                }
            } catch {
                if Task.isCancelled { return }
                let message = PlaybackTrouble.explain(error)
                await MainActor.run {
                    guard self.currentIndex == index else { return }
                    self.endBackgroundTask()
                    self.fail(message, index: index)
                }
            }
        }
    }

    private func makeItem(_ audio: ResolvedAudio) -> AVPlayerItem {
        var options: [String: Any] = [:]
        if !audio.stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = audio.stream.headers }
        let item = AVPlayerItem(asset: AVURLAsset(url: audio.stream.url, options: options))
        item.audioTimePitchAlgorithm = pitchFollowsRate ? .varispeed : .spectral
        return item
    }

    private func adopt(_ item: AVPlayerItem, _ audio: ResolvedAudio) {
        currentItem = item
        currentAudio = audio
        serving = audio.match
        servingStream = audio.stream
        servingLocal = audio.isLocal
        isLoading = item.status != .readyToPlay
        measureBitrateIfNeeded(audio)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item) }
        }
        updateNowPlaying()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let d = item.duration.seconds
            if d.isFinite && d > 0 { duration = d }
            updateNowPlaying()
            // Источник не сообщил битрейт и замер по размеру не удался — берём оценку AVFoundation.
            if (servingStream?.bitrate ?? 0) <= 0 {
                let asset = item.asset
                asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
                    let rate = asset.tracks(withMediaType: .audio).first?.estimatedDataRate ?? 0
                    guard rate > 0 else { return }
                    DispatchQueue.main.async {
                        guard let self = self, item === self.currentItem, (self.servingStream?.bitrate ?? 0) <= 0 else { return }
                        let kbps = PlayerController.roundKbps(Double(rate) / 1000)
                        self.servingStream?.bitrate = kbps * 1000
                        self.currentAudio?.stream.bitrate = kbps * 1000
                    }
                }
            }
        case .failed:
            playbackFailed()
        default:
            break
        }
    }

    /// Поток сломался: один раз пробуем другую версию, потом — следующий трек.
    private func playbackFailed() {
        guard let c = currentIndex, let track = current else { return }
        let at = position
        if let audio = currentAudio {
            let q = track.audioQuery
            let e = engine
            Task { await e.reportBroken(q, audio.match) }
        }
        if !retriedCurrent {
            load(c, autoplay: wantsPlay, startAt: at, isRetry: true)
        } else {
            fail(L("ios_audio_stream_failed"), index: c)
        }
    }

    private func fail(_ message: String, index: Int) {
        isLoading = false
        // Трек не найден — идём дальше по очереди, но не больше трёх неудач подряд.
        if wantsPlay, consecutiveFailures < 3, let n = nextIndex(auto: false), n != index {
            consecutiveFailures += 1
            load(n, autoplay: true)
        } else {
            consecutiveFailures = 0
            wantsPlay = false
            isPlaying = false
        }
        errorText = message
    }

    // MARK: - Скорость

    private func startPlayer() {
        player.play()
        if playbackRate != 1 { player.rate = playbackRate }
    }

    func setRate(_ rate: Float) {
        playbackRate = min(2, max(0.5, rate))
        if isPlaying || wantsPlay { player.rate = playbackRate }
    }

    func setPitchFollowsRate(_ on: Bool) {
        pitchFollowsRate = on
        settings.set(PK.varispeed, on)
        for item in player.items() { item.audioTimePitchAlgorithm = on ? .varispeed : .spectral }
    }

    // MARK: - Битрейт (CRITICAL §2.6: источник не сообщил — меряем размер файла / длительность)

    private var bitrateTask: Task<Void, Never>?

    private func measureBitrateIfNeeded(_ audio: ResolvedAudio) {
        bitrateTask?.cancel()
        guard audio.stream.bitrate <= 0 || audio.isLocal, !audio.stream.isHLS else { return }
        let stream = audio.stream
        let fallback = Double(current?.durationMs ?? 0) / 1000
        bitrateTask = Task { [weak self] in
            guard let bytes = await PlayerController.contentLength(stream), bytes > 0, !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self, self.servingStream?.url == stream.url else { return }
                let d = self.duration > 1 ? self.duration : fallback
                guard d > 1 else { return }
                let kbps = PlayerController.roundKbps(Double(bytes) * 8 / d / 1000)
                self.servingStream?.bitrate = kbps * 1000
                self.currentAudio?.stream.bitrate = kbps * 1000
            }
        }
    }

    /// Округление к ближайшему стандартному битрейту, если он в пределах 6 %.
    static func roundKbps(_ raw: Double) -> Int {
        let standard: [Double] = [64, 96, 128, 160, 192, 224, 256, 320]
        if let s = standard.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(s - raw) / s < 0.06 { return Int(s) }
        return Int(raw.rounded())
    }

    static func contentLength(_ s: AudioStream) async -> Int64? {
        if s.url.isFileURL {
            return (try? FileManager.default.attributesOfItem(atPath: s.url.path)[.size] as? NSNumber)?.int64Value
        }
        var r = URLRequest(url: s.url, timeoutInterval: 10)
        r.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (k, v) in s.headers { r.setValue(v, forHTTPHeaderField: k) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int64?, Never>) in
            URLSession.shared.dataTask(with: r) { _, resp, _ in
                guard let h = resp as? HTTPURLResponse else { return cont.resume(returning: nil) }
                if let range = h.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let n = Int64(total) {
                    return cont.resume(returning: n)
                }
                cont.resume(returning: h.statusCode == 200 && h.expectedContentLength > 0 ? h.expectedContentLength : nil)
            }.resume()
        }
    }

    // MARK: - Подготовка следующего

    private func dropPreload() {
        preloadTask?.cancel()
        if let pre = preloaded, player.items().contains(pre.item), player.currentItem !== pre.item {
            player.remove(pre.item)
        }
        preloaded = nil
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        guard preloaded == nil, repeatMode != .one, let n = nextIndex(auto: true), n != currentIndex else { return }
        let track = queue[n]
        preloadTask = Task { [weak self] in
            guard let self = self else { return }
            // Не мешаем старту текущего трека.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            guard let audio = try? await self.resolve(track), !Task.isCancelled else { return }
            if !audio.isLocal, RecommendedTracks.shared.tooLow(track.id, bitrate: audio.stream.bitrate) {
                // Рекомендация с плохим звуком убирается из очереди заранее.
                await MainActor.run {
                    guard let i = self.queue.firstIndex(where: { $0.id == track.id }), i != self.currentIndex else { return }
                    self.remove(at: i)
                }
                return
            }
            await MainActor.run {
                guard self.preloaded == nil, self.nextIndex(auto: true) == n, self.queue.indices.contains(n),
                      self.queue[n].id == track.id, let cur = self.currentItem else { return }
                let item = self.makeItem(audio)
                if self.player.canInsert(item, after: cur) {
                    self.player.insert(item, after: cur)
                    self.preloaded = (n, item, audio)
                }
            }
        }
    }

    // MARK: - Наблюдение за плеером

    private func observePlayer() {
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPlaying = status == .playing
                if self.currentItem != nil { self.isLoading = status == .waitingToPlayAtSpecifiedRate }
                if self.isPlaying { self.consecutiveFailures = 0 }
                self.lastTick = nil
                self.updateNowPlaying()
            }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] p, _ in
            let item = p.currentItem
            DispatchQueue.main.async { self?.playerItemChanged(item) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            self?.tick(time.seconds)
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(itemEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        nc.addObserver(self, selector: #selector(itemFailed(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        nc.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(saveImmediately), name: UIApplication.willTerminateNotification, object: nil)
        nc.addObserver(self, selector: #selector(saveImmediately), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    /// `AVQueuePlayer` сам перешёл на подготовленный трек.
    private func playerItemChanged(_ item: AVPlayerItem?) {
        guard let item = item, let pre = preloaded, item === pre.item, item !== currentItem,
              queue.indices.contains(pre.index) else { return }
        recordHistoryIfNeeded()
        preloaded = nil
        currentIndex = pre.index
        position = 0
        duration = Double(queue[pre.index].durationMs) / 1000
        retriedCurrent = false
        resetPlayCounter()
        adopt(item, pre.audio)
        loadArtwork(queue[pre.index])
        schedulePreload()
        scheduleSave()
        extendIfNeeded()
        if sleepAtEndOfTrack { finishSleepTimer() }
    }

    @objc private func itemEnded(_ note: Notification) {
        let ended = note.object as? AVPlayerItem
        DispatchQueue.main.async {
            guard let item = ended, item === self.currentItem else { return }
            // Подготовленный следующий подхватит сам плеер (см. playerItemChanged).
            if let pre = self.preloaded, self.player.items().contains(pre.item) { return }
            if self.sleepAtEndOfTrack {
                self.finishSleepTimer()
                return
            }
            if self.repeatMode == .one {
                // AVQueuePlayer уже выкинул доигравший трек: ставим его заново.
                self.recordHistoryIfNeeded()
                self.resetPlayCounter()
                if let audio = self.currentAudio {
                    let again = self.makeItem(audio)
                    self.player.removeAllItems()
                    self.player.insert(again, after: nil)
                    self.adopt(again, audio)
                    self.activateSession()
                    self.startPlayer()
                } else if let c = self.currentIndex {
                    self.load(c, autoplay: true)
                }
                return
            }
            if let n = self.nextIndex(auto: true) {
                self.load(n, autoplay: true)
            } else {
                self.recordHistoryIfNeeded()
                self.wantsPlay = false
                self.isPlaying = false
                self.updateNowPlaying()
            }
        }
    }

    @objc private func itemFailed(_ note: Notification) {
        let failed = note.object as? AVPlayerItem
        DispatchQueue.main.async {
            guard let item = failed, item === self.currentItem else { return }
            self.playbackFailed()
        }
    }

    private func tick(_ seconds: Double) {
        guard currentItem != nil, seconds.isFinite else { return }
        position = seconds
        let now = Date()
        if isPlaying, let last = lastTick {
            let d = now.timeIntervalSince(last)
            if d > 0 && d < 2 { playedSeconds += d }
        }
        lastTick = isPlaying ? now : nil
    }

    // MARK: - Звуковая сессия

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        DispatchQueue.main.async {
            switch type {
            case .began:
                self.resumeAfterInterruption = self.wantsPlay
                self.player.pause()
            case .ended:
                if self.resumeAfterInterruption && options.contains(.shouldResume) { self.resume() }
                self.resumeAfterInterruption = false
            @unknown default:
                break
            }
        }
    }

    /// Наушники отключили — пауза.
    @objc private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { self.pause() }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "resolve") { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Экран блокировки и пульт

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skipNext(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skipPrevious(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistNames,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let a = t.albumName { info[MPMediaItemPropertyAlbumTitle] = a }
        if let art = artwork, art.url == t.artworkUrl {
            let image = art.image
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
    }

    private func loadArtwork(_ track: Track) {
        artworkTask?.cancel()
        guard let raw = track.artworkUrl, artwork?.url != raw else { return }
        artworkTask = Task { [weak self] in
            for url in SpotifyImageCDN.candidates(raw) {
                guard let r = try? await HTTP.get(url, timeout: 15), r.isSuccess, let image = UIImage(data: r.data) else { continue }
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.artwork = (raw, image)
                    self?.updateNowPlaying()
                }
                return
            }
        }
    }

    // MARK: - История (PLAY-035)

    private func resetPlayCounter() {
        playedSeconds = 0
        lastTick = nil
        historyRecorded = false
    }

    /// Засчитывается половина трека, но не меньше порога (30 с по умолчанию) и не больше 4 минут.
    private func recordHistoryIfNeeded() {
        guard !historyRecorded, let t = current, !(settings.get(PK.pauseListenHistory) ?? false) else { return }
        let minimum = Double(settings.get(PK.historyDuration) ?? 30)
        let length = duration > 0 ? duration : Double(t.durationMs) / 1000
        let threshold = min(max(length / 2, minimum), 240)
        guard playedSeconds >= min(threshold, max(length - 1, 1)) else { return }
        historyRecorded = true
        RecentlyPlayed.shared.record(t)
        let played = Int64(playedSeconds * 1000)
        let db = database
        DispatchQueue.global(qos: .utility).async { SongStore.recordPlay(db, track: t, playTimeMs: played) }
        onListened?()
    }

    // MARK: - Таймер сна (PLAY-014)

    var sleepTimerActive: Bool { sleepTimerEnd != nil || sleepAtEndOfTrack }

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sleepTick() }
    }

    func startSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEnd = nil
        sleepAtEndOfTrack = false
        player.volume = settings.get(PK.playerVolume) ?? 1
    }

    private func sleepTick() {
        guard let end = sleepTimerEnd else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            if settings.get(PK.sleepTimerStopAfterCurrentSong) ?? false {
                sleepTimer?.invalidate()
                sleepTimer = nil
                sleepTimerEnd = nil
                sleepAtEndOfTrack = true
            } else {
                finishSleepTimer()
            }
        } else if left < 60, settings.get(PK.sleepTimerFadeOut) ?? false {
            // Затухание в последнюю минуту.
            player.volume = (settings.get(PK.playerVolume) ?? 1) * Float(left / 60)
        }
        objectWillChange.send()
    }

    private func finishSleepTimer() {
        pause()
        cancelSleepTimer()
    }

    // MARK: - Сохранение очереди (PLAY-006)

    private struct Saved: Codable {
        var queue: [Track]
        var index: Int?
        var position: Double
        var title: String?
        var shuffleOrder: [Int]
    }

    private static var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("persistent_queue.json")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveImmediately() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    @objc private func saveImmediately() {
        saveWork?.cancel()
        let url = Self.saveURL
        guard settings.get(PK.persistentQueue) ?? true else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = Saved(queue: queue, index: currentIndex, position: position, title: queueTitle, shuffleOrder: shuffleOrder)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func restoreQueue() {
        guard settings.get(PK.persistentQueue) ?? true,
              let data = try? Data(contentsOf: Self.saveURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.queue.isEmpty else { return }
        queue = saved.queue
        queueTitle = saved.title
        shuffleOrder = saved.shuffleOrder.count == saved.queue.count ? saved.shuffleOrder : Array(saved.queue.indices)
        if let i = saved.index, queue.indices.contains(i) {
            currentIndex = i
            position = saved.position
            duration = Double(queue[i].durationMs) / 1000
            loadArtwork(queue[i])
        }
    }
}

/// Почему трек не играет, понятными словами (как `ui/player/PlaybackError.kt` + `resolver/SourceTrouble.kt`):
/// обрыв сети/VPN, YouTube отказал этому адресу («не бот» — помогает смена сервера VPN), возраст/регион.
enum PlaybackTrouble {
    static func explain(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return L("playback_err_network_title") + ". " + L("playback_err_network")
            default: break
            }
        }
        if let block = YouTubeProvider.lastBlock {
            if block.contains("LOGIN_REQUIRED") || (block.contains("UNPLAYABLE") && block.contains("bot")) {
                return L("download_issue_youtube_refused")
            }
            if block.contains("AGE") || block.contains("UNPLAYABLE") {
                return L("playback_err_yt_restricted_title") + ". " + L("playback_err_yt_restricted")
            }
            if block.contains("NSURLErrorDomain") || block.contains("timed out") || block.contains("offline") {
                return L("playback_err_yt_unreachable_title") + ". " + L("playback_err_yt_unreachable")
            }
        }
        return error.localizedDescription
    }
}
