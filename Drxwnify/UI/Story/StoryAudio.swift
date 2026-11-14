import AVFoundation
import Combine

/// Звук итогов (Android 2.3.0 `StoryAudio`): свой плеер, звук ищется теми же источниками, что у основного (скачанное, ВК, YouTube…),
/// очередь не трогается. Трек начинается с трети длительности; громкость растёт с нуля до полной к появлению названия
/// (~2,9 с от начала страницы, кривая `smoothstep(x)·x`); разгон начинается, когда звук реально пошёл, но кончается вовремя
/// (не быстрее 600 мс). Смена трека — затухание 700 мс; тот же трек на следующей странице просто играет дальше; страница без
/// трека — тишина. Громкость по умолчанию — 0,8, дальше её меняет только ползунок. Пауза истории музыку не останавливает.
///
/// Поиск звука долгий (секунды), поэтому все треки истории ищутся сразу при открытии — пока идут первые страницы без музыки.
final class StoryAudio: ObservableObject {
    @Published var volume: Float = 0.8 { didSet { applyVolume() } }

    private let player = AVPlayer()
    private let engine: AudioFallbackEngine
    private let local: ((Track) -> ResolvedAudio?)?
    private var current: String?
    private var ramp: Float = 0
    private var rampTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var found: [String: Task<ResolvedAudio?, Never>] = [:]
    private var statusObservation: NSKeyValueObservation?

    init(engine: AudioFallbackEngine, local: ((Track) -> ResolvedAudio?)?) {
        self.engine = engine
        self.local = local
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
    }

    private func applyVolume() { player.volume = volume * ramp }

    /// Звук треков истории ищется заранее, по порядку страниц.
    func prepare(_ tracks: [Track]) {
        for t in tracks { _ = audio(for: t) }
    }

    private func audio(for track: Track) -> Task<ResolvedAudio?, Never> {
        if let t = found[track.id] { return t }
        let localHit = local?(track)
        let engine = self.engine
        let t = Task<ResolvedAudio?, Never> {
            if let l = localHit { return l }
            return try? await engine.stream(for: track.audioQuery)
        }
        found[track.id] = t
        return t
    }

    /// Трек страницы (nil — тишина); `fullAt` — когда громкость должна стать полной (появление названия трека).
    func play(_ track: Track?, fullAt: Date = Date().addingTimeInterval(2.9)) {
        if current == track?.id { return }
        current = track?.id
        loadTask?.cancel()
        fade(to: 0, over: 0.7) { [weak self] in
            guard let self = self else { return }
            guard let track = track else { self.player.pause(); return }
            let pending = self.audio(for: track)
            self.loadTask = Task { [weak self] in
                guard let audio = await pending.value, !Task.isCancelled else { return }
                await MainActor.run { self?.start(audio, track: track, fullAt: fullAt) }
            }
        }
    }

    private func start(_ audio: ResolvedAudio, track: Track, fullAt: Date) {
        guard current == track.id else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        var options: [String: Any] = [:]
        if !audio.stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = audio.stream.headers }
        let item = AVPlayerItem(asset: AVURLAsset(url: audio.stream.url, options: options))
        player.replaceCurrentItem(with: item)
        ramp = 0
        applyVolume()
        // С трети длительности — когда элемент готов (до этого перемотка теряется); длина — из каталога или из файла.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                guard let self = self, self.player.currentItem === item, self.statusObservation != nil else { return }
                self.statusObservation = nil
                var length = track.durationMs > 0 ? Double(track.durationMs) / 1000 : 0
                if length <= 0, item.duration.isNumeric { length = item.duration.seconds }
                let begin = { [weak self] in
                    guard let self = self, self.player.currentItem === item else { return }
                    self.player.play()
                    self.fade(to: 1, over: max(0.6, fullAt.timeIntervalSinceNow), curve: true, then: nil)
                }
                if length > 60 {
                    self.player.seek(to: CMTime(seconds: length / 3, preferredTimescale: 600)) { _ in DispatchQueue.main.async(execute: begin) }
                } else {
                    begin()
                }
            }
        }
    }

    private func fade(to target: Float, over seconds: TimeInterval, curve: Bool = false, then: (() -> Void)?) {
        rampTimer?.invalidate()
        let from = ramp
        if seconds <= 0 || from == target { ramp = target; applyVolume(); then?(); return }
        let start = Date()
        let rising = target > from
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let x = Float(min(1, Date().timeIntervalSince(start) / seconds))
            let k = curve && rising ? (x * x * (3 - 2 * x)) * x : x
            self.ramp = from + (target - from) * k
            self.applyVolume()
            if x >= 1 { t.invalidate(); then?() }
        }
        // И во время свайпа (режим отслеживания жестов) громкость меняется.
        if let t = rampTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        loadTask?.cancel()
        for t in found.values { t.cancel() }
        found = [:]
        rampTimer?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
    }
}
