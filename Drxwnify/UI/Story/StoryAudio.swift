import AVFoundation
import Combine

/// Звук итогов (Android 2.3.0 `StoryAudio`): свой плеер, звук ищется теми же источниками, что у основного (ВК, YouTube…),
/// очередь не трогается. Трек начинается с трети длительности; громкость растёт с нуля до полной к появлению названия
/// (~2,8 с, кривая `smoothstep(x)·x`); смена трека — затухание 700 мс; тот же трек на следующей странице просто играет дальше.
/// Громкость по умолчанию — 0,8 от полной, дальше её меняет только ползунок.
final class StoryAudio: ObservableObject {
    @Published var volume: Float = 0.8 { didSet { applyVolume() } }
    @Published var paused = false { didSet { paused ? player.pause() : (current != nil ? player.play() : ()) } }

    private let player = AVPlayer()
    private let engine: AudioFallbackEngine
    private var current: String?
    private var ramp: Float = 1
    private var rampTimer: Timer?
    private var loadTask: Task<Void, Never>?

    init(engine: AudioFallbackEngine) {
        self.engine = engine
        player.volume = 0
    }

    private func applyVolume() { player.volume = volume * ramp }

    /// Трек страницы; `riseBy` — к какому моменту от начала страницы громкость должна стать полной.
    func play(_ track: Track?, riseBy: TimeInterval = 2.85) {
        guard let track = track else { return }
        if current == track.id { return }
        current = track.id
        let started = Date()
        fade(to: 0, over: 0.7) { [weak self] in
            guard let self = self else { return }
            self.loadTask?.cancel()
            self.loadTask = Task {
                guard let audio = try? await self.engine.stream(for: track.audioQuery), !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.current == track.id else { return }
                    let asset = AVURLAsset(url: audio.stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": audio.stream.headers])
                    let item = AVPlayerItem(asset: asset)
                    self.player.replaceCurrentItem(with: item)
                    let length = track.durationMs > 0 ? Double(track.durationMs) / 1000 : 0
                    if length > 0 { self.player.seek(to: CMTime(seconds: length / 3, preferredTimescale: 600)) }
                    self.ramp = 0
                    self.applyVolume()
                    if !self.paused { self.player.play() }
                    // Разгон кончается вовремя, даже если звук грузился (но не быстрее 600 мс).
                    let left = max(0.6, riseBy - Date().timeIntervalSince(started))
                    self.fade(to: 1, over: left, curve: true, then: nil)
                }
            }
        }
    }

    private func fade(to target: Float, over seconds: TimeInterval, curve: Bool = false, then: (() -> Void)?) {
        rampTimer?.invalidate()
        let from = ramp
        if seconds <= 0 || from == target { ramp = target; applyVolume(); then?(); return }
        let start = Date()
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let x = Float(min(1, Date().timeIntervalSince(start) / seconds))
            let k = curve ? (x * x * (3 - 2 * x)) * x : x
            self.ramp = from + (target - from) * k
            self.applyVolume()
            if x >= 1 { t.invalidate(); then?() }
        }
    }

    func stop() {
        loadTask?.cancel()
        rampTimer?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
    }
}
