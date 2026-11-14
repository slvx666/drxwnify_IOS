import AVFoundation
import MediaToolbox

/// Эквалайзер, как графический EQ Android (`GraphicEq` + `CustomEqualizerAudioProcessor`): 10 пиковых фильтров
/// (Q 1,41) на частотах 32 Гц…16 кГц, ±12 дБ, без предусиления, мягкий ограничитель против клиппинга.
/// Звук трека обрабатывается через `MTAudioProcessingTap` (аудиомикс элемента плеера).
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let maxDb: Float = 12

    enum Preset: String, CaseIterable {
        case flat, bass, vocals, guitar, bassGuitar, drums, piano, strings, speech, metal, electronic, air, night, phoneSpeaker, oldRadio, underwater

        var title: String {
            switch self {
            case .flat: return L("eq_flat")
            case .bass: return L("eq_bass")
            case .vocals: return L("eq_vocals")
            case .guitar: return L("eq_guitar")
            case .bassGuitar: return L("eq_bass_guitar")
            case .drums: return L("eq_drums")
            case .piano: return L("eq_piano")
            case .strings: return L("eq_strings")
            case .speech: return L("eq_speech")
            case .metal: return L("eq_metal")
            case .electronic: return L("eq_electronic")
            case .air: return L("eq_air")
            case .night: return L("eq_night")
            case .phoneSpeaker: return L("eq_phone_speaker")
            case .oldRadio: return L("eq_old_radio")
            case .underwater: return L("eq_underwater")
            }
        }

        var gains: [Float] {
            switch self {
            case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            case .bass: return [7, 6, 4, 1.5, 0, 0, 0, 0, 0, 0]
            case .vocals: return [-2, -2, -1, 0, 1, 2.5, 4.5, 3, 1, 0]
            case .guitar: return [-1, 0, 1, -2, 0, 1.5, 3.5, 4, 2, 0]
            case .bassGuitar: return [3, 5, 4, 2, 0, 1.5, 2.5, 0, -1, -2]
            case .drums: return [4, 5, 2, -2, -2, 0, 2, 4, 3, 2]
            case .piano: return [0, 1, 2, 2, 1, 0, 1.5, 2.5, 2, 1]
            case .strings: return [-1, 0, 1, 2, 2, 1, 1, 2.5, 3, 3]
            case .speech: return [-6, -4, -1, 1, 2.5, 3.5, 3.5, 2, 0, -2]
            case .metal: return [4, 4, 2, -1, -3, -2, 1, 3.5, 4, 3]
            case .electronic: return [6, 5, 2, 0, -1, 0, 1, 2.5, 4, 5]
            case .air: return [0, 0, 0, 0, 0, 0, 0.5, 2, 4, 6]
            case .night: return [-4, -3, -1, 0, 1, 1.5, 1, -1, -3, -4]
            case .phoneSpeaker: return [-12, -10, -4, 1, 2, 3, 3, 2, 1, 0]
            case .oldRadio: return [-12, -12, -8, -2, 3, 5, 3, -6, -12, -12]
            case .underwater: return [6, 6, 4, 2, -2, -6, -10, -12, -12, -12]
            }
        }
    }

    @Published var enabled: Bool { didSet { save(); publish() } }
    @Published var gains: [Float] { didSet { save(); publish() } }

    private let defaults = UserDefaults.standard
    /// Что читает звуковой поток: включён ли и усиления полос (под замком — пишется с главного потока).
    fileprivate let state = SharedLock(Shared())

    fileprivate struct Shared {
        var enabled = false
        var gains = [Float](repeating: 0, count: 10)
        var version = 0
    }

    private init() {
        enabled = defaults.bool(forKey: "eq_enabled")
        let g = defaults.array(forKey: "eq_gains") as? [Double] ?? []
        gains = g.count == Self.frequencies.count ? g.map { Float($0) } : Preset.flat.gains
        publish()
    }

    var matchingPreset: Preset? { Preset.allCases.first { $0.gains == gains } }

    private func save() {
        defaults.set(enabled, forKey: "eq_enabled")
        defaults.set(gains.map { Double($0) }, forKey: "eq_gains")
    }

    private func publish() {
        let e = enabled, g = gains
        state.withLock { s in
            s.enabled = e
            s.gains = g
            s.version += 1
        }
    }

    // MARK: - Подключение к элементу плеера

    /// Вешает обработку на элемент (после загрузки его дорожек). Без звуковой дорожки — ничего.
    func attach(to item: AVPlayerItem) {
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak item] in
            guard let item = item, asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                  let track = asset.tracks(withMediaType: .audio).first else { return }
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
                  let created = tap else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = created
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            DispatchQueue.main.async { item.audioMix = mix }
        }
    }
}

/// Простой замок (iOS 14: `OSAllocatedLock` нет).
fileprivate final class SharedLock<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Обработка звука (поток звука, без выделений памяти)

/// Состояние одного подключения: фильтры по каналам.
private final class TapContext {
    unowned let eq: Equalizer
    var sampleRate: Double = 44100
    var isFloat = true
    var nonInterleaved = true
    var channels = 2
    var version = -1
    var enabled = false
    /// Коэффициенты: по полосе b0 b1 b2 a1 a2.
    var coeffs = [Double](repeating: 0, count: 50)
    /// Состояние: [канал][полоса] x1 x2 y1 y2.
    var history = [Double](repeating: 0, count: 8 * 10 * 4)

    init(eq: Equalizer) { self.eq = eq }

    func refresh() {
        let s = eq.state.withLock { $0 }
        guard s.version != version else { return }
        version = s.version
        enabled = s.enabled && s.gains.contains { $0 != 0 }
        for (i, f) in Equalizer.frequencies.enumerated() {
            // RBJ «peaking EQ».
            let a = pow(10, Double(s.gains[i]) / 40)
            let w0 = 2 * Double.pi * min(f, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * 1.41)
            let cw = cos(w0)
            let a0 = 1 + alpha / a
            coeffs[i * 5 + 0] = (1 + alpha * a) / a0
            coeffs[i * 5 + 1] = (-2 * cw) / a0
            coeffs[i * 5 + 2] = (1 - alpha * a) / a0
            coeffs[i * 5 + 3] = (-2 * cw) / a0
            coeffs[i * 5 + 4] = (1 - alpha / a) / a0
        }
    }

    @inline(__always) func sample(_ x: Double, channel: Int) -> Double {
        var v = x
        let base = min(channel, 7) * 40
        for b in 0..<10 {
            let h = base + b * 4
            let c = b * 5
            let y = coeffs[c] * v + coeffs[c + 1] * history[h] + coeffs[c + 2] * history[h + 1]
                - coeffs[c + 3] * history[h + 2] - coeffs[c + 4] * history[h + 3]
            history[h + 1] = history[h]; history[h] = v
            history[h + 3] = history[h + 2]; history[h + 2] = y
            v = y
        }
        // Мягкий ограничитель: до 0,9 без изменений, выше — плавно к 1.
        let m = abs(v)
        if m > 0.9 { v = (v < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((m - 0.9) / 0.1)) }
        return v
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    let eq = Unmanaged<Equalizer>.fromOpaque(clientInfo!).takeUnretainedValue()
    storageOut.pointee = Unmanaged.passRetained(TapContext(eq: eq)).toOpaque()
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let f = format.pointee
    ctx.sampleRate = f.mSampleRate > 0 ? f.mSampleRate : 44100
    ctx.isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
    ctx.nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    ctx.channels = Int(f.mChannelsPerFrame)
    ctx.version = -1
    for i in ctx.history.indices { ctx.history[i] = 0 }
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, buffers, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.refresh()
    guard ctx.enabled, ctx.isFloat else { return }
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    let n = Int(framesOut.pointee)
    if ctx.nonInterleaved {
        for (ch, buf) in list.enumerated() {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<min(n, Int(buf.mDataByteSize) / 4) { data[i] = Float(ctx.sample(Double(data[i]), channel: ch)) }
        }
    } else if let buf = list.first, let data = buf.mData?.assumingMemoryBound(to: Float.self) {
        let chs = max(1, ctx.channels)
        for i in 0..<min(n * chs, Int(buf.mDataByteSize) / 4) { data[i] = Float(ctx.sample(Double(data[i]), channel: i % chs)) }
    }
}
