import SwiftUI
import AVFoundation
import Photos

/// «Скачать видео с YouTube» (Android `VideoClipDialog` + `VideoClipDownloader`): клипы трека на YouTube, вероятный
/// официальный первым; качество (по умолчанию 1080p, иначе ближайшее ниже); картинка и звук качаются отдельно,
/// склеиваются без перекодирования и сохраняются в «Фото».
struct VideoClipSheet: View {
    let track: Track
    @Environment(\.presentationMode) private var presentation
    @StateObject private var model = VideoClipModel()
    @State private var selected: String?
    /// Просмотр клипа (Android: долгое нажатие) — три кадра из начала, середины и конца.
    @State private var preview: YouTubeProvider.Clip?

    static let heights = [1080, 720, 480, 360]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text(L("video_clip_quality")), footer: Text(L("video_clip_quality_hint"))) {
                    Picker(L("video_clip_quality"), selection: $model.height) {
                        ForEach(Self.heights, id: \.self) { Text("\($0)p").tag($0) }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                if let status = model.status {
                    Section {
                        HStack(spacing: 10) {
                            if model.busy { ProgressView() }
                            Text(status).font(.subheadline)
                        }
                        if let p = model.progress { ProgressView(value: p) }
                    }
                }
                Section {
                    if model.searching {
                        HStack { ProgressView(); Text(L("video_clip_searching")).foregroundColor(.secondary) }
                    } else if model.clips.isEmpty {
                        Text(L("video_clip_none")).foregroundColor(.secondary)
                    }
                    ForEach(model.clips, id: \.videoId) { c in
                        row(c)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = c.videoId }
                            .onLongPressGesture { preview = c }
                    }
                }
                if let id = selected, let clip = model.clips.first(where: { $0.videoId == id }) {
                    Section {
                        Button(action: { model.download(clip, title: "\(track.artistNames) - \(track.title)") }) {
                            Label(L("action_download"), systemImage: "arrow.down.circle.fill").font(.headline)
                        }
                        .disabled(model.busy)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("video_clip_download"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .sheet(item: Binding(get: { preview.map { PreviewItem(clip: $0) } }, set: { if $0 == nil { preview = nil } })) { item in
            ClipPreview(clip: item.clip, onPick: { selected = item.clip.videoId; preview = nil })
        }
        .onAppear {
            model.search(track)
        }
        .onReceive(model.$clips) { list in if selected == nil { selected = list.first?.videoId } }
    }

    private func row(_ c: YouTubeProvider.Clip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected == c.videoId ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected == c.videoId ? .accentColor : .secondary)
            ClipFrame(url: c.thumbnail).frame(width: 96, height: 54)
                .onTapGesture { preview = c }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.subheadline).lineLimit(2).foregroundColor(.primary)
                Text([c.channel, c.durationSec.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                if let k = kind(c) { Text(k.0).font(.caption2).foregroundColor(k.1) }
            }
        }
    }

    /// Метка как на Android: метка YouTube, иначе — меняется ли картинка (по трём кадрам).
    private func kind(_ c: YouTubeProvider.Clip) -> (String, Color)? {
        switch c.videoType {
        case "MUSIC_VIDEO_TYPE_OMV": return (L("video_clip_kind_official"), .accentColor)
        case "MUSIC_VIDEO_TYPE_ATV": return (L("video_clip_kind_audio"), .orange)
        default: break
        }
        if let m = model.motion[c.videoId] {
            return m < VideoClipModel.stillMotion ? (L("video_clip_kind_still"), .orange) : (L("video_clip_kind_moving"), .accentColor)
        }
        return c.videoType == "MUSIC_VIDEO_TYPE_UGC" ? (L("video_clip_kind_fan"), .secondary) : nil
    }
}

private struct PreviewItem: Identifiable {
    let clip: YouTubeProvider.Clip
    var id: String { clip.videoId }
}

/// Кадр 16:9 с обрезкой.
private struct ClipFrame: View {
    let url: String
    var body: some View {
        GeometryReader { g in
            ArtworkView(url: url, size: g.size.width, cornerRadius: 0)
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Просмотр: три автоматических кадра YouTube (около ¼, ½ и ¾ видео) и «Выбрать это».
private struct ClipPreview: View {
    let clip: YouTubeProvider.Clip
    let onPick: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(1...3, id: \.self) { i in
                        ClipFrame(url: "https://i.ytimg.com/vi/\(clip.videoId)/hq\(i).jpg")
                            .aspectRatio(16 / 9, contentMode: .fit)
                    }
                    Text(clip.title).font(.headline)
                    Text(clip.channel).font(.subheadline).foregroundColor(.secondary)
                    Button(action: onPick) {
                        Text(L("video_clip_pick")).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(Color(.systemBackground)).background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

final class VideoClipModel: ObservableObject {
    @Published var clips: [YouTubeProvider.Clip] = []
    @Published var searching = false
    @Published var busy = false
    @Published var status: String?
    @Published var progress: Double?
    @Published var height = 1080
    /// Насколько меняется картинка, 0…1 (три маленьких кадра YouTube): статичная обложка ≈ 0.
    @Published var motion: [String: Double] = [:]
    static let stillMotion = 0.06
    /// iOS: варианты, похожие на трек меньше чем на 80 %, не показываются (просьба владельца; на Android пока все).
    static let minSimilarity = 0.8

    private let youtube = YouTubeProvider()
    private static let official = try! NSRegularExpression(pattern: "official (music )?video|music video|\\bmv\\b|клип|official clip", options: .caseInsensitive)
    private static let notClip = try! NSRegularExpression(
        pattern: "lyric|lyrics|текст|visuali[sz]er|audio\\)|\\(audio|official audio|reaction|cover|karaoke|live at|live in|\\blive\\b|remix|sped up|slowed|nightcore|8d|tutorial|lesson",
        options: .caseInsensitive)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    func search(_ track: Track) {
        guard clips.isEmpty, !searching else { return }
        searching = true
        let artist = track.artists.first?.name ?? ""
        let titleKey = Self.norm(track.title), artistKey = Self.norm(artist)
        let duration = track.durationMs / 1000
        let yt = youtube
        Task {
            let found = (try? await yt.searchClips([artist, track.title].filter { !$0.isEmpty }.joined(separator: " "))) ?? []
            // Оценка как на Android: название, исполнитель, «official video», метка YouTube, длина.
            func score(_ c: YouTubeProvider.Clip) -> Int {
                let name = Self.norm(c.title), channel = Self.norm(c.channel)
                var s = 0
                if !titleKey.isEmpty && name.contains(titleKey) { s += 40 }
                if !artistKey.isEmpty && (channel.contains(artistKey) || name.contains(artistKey)) { s += 30 }
                if Self.has(Self.official, c.title) { s += 15 }
                if c.videoType == "MUSIC_VIDEO_TYPE_OMV" { s += 20 }
                if c.videoType == "MUSIC_VIDEO_TYPE_ATV" { s -= 30 }
                if Self.has(Self.notClip, c.title) && !Self.has(Self.notClip, track.title) { s -= 35 }
                if let d = c.durationSec, duration > 0 {
                    let off = abs(d - duration)
                    s += off <= 5 ? 15 : (off <= 30 ? 8 : (off <= 90 ? 0 : -20))
                }
                return s
            }
            var seen = Set<String>()
            let ranked = found.filter { seen.insert($0.videoId).inserted && Self.similarity(track, $0) >= Self.minSimilarity }
                .sorted { score($0) > score($1) }.prefix(8)
            await MainActor.run {
                clips = Array(ranked)
                searching = false
            }
            for c in ranked {
                if let m = await Self.motionOf(c.videoId) { await MainActor.run { motion[c.videoId] = m } }
            }
        }
    }

    /// Доля слов названия трека (без скобок и feat.) и имени исполнителя, которые есть в названии клипа или канале.
    static func similarity(_ track: Track, _ c: YouTubeProvider.Clip) -> Double {
        let core = track.title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .components(separatedBy: " - ").first ?? track.title
        let want = norm(core).split(separator: " ").map(String.init) + norm(track.artists.first?.name ?? "").split(separator: " ").map(String.init)
        guard !want.isEmpty else { return 0 }
        let have = Set(norm(c.title + " " + c.channel).split(separator: " ").map(String.init))
        let hit = want.filter { have.contains($0) }.count
        return Double(hit) / Double(want.count)
    }

    /// Разница трёх кадров 32×18 по яркости (как Android `motionOf`).
    static func motionOf(_ videoId: String) async -> Double? {
        var frames: [[Double]] = []
        for i in 1...3 {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(i).jpg"),
                  let r = try? await HTTP.get(url), r.isSuccess, let img = UIImage(data: r.data)?.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: 32 * 18)
            guard let ctx = CGContext(data: &px, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 32, height: 18))
            frames.append(px.map { Double($0) / 255 })
        }
        func diff(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count) }
        let d = (diff(frames[0], frames[1]) + diff(frames[1], frames[2]) + diff(frames[0], frames[2])) / 3 * 4
        return min(1, max(0, d))
    }

    func download(_ clip: YouTubeProvider.Clip, title: String) {
        busy = true
        progress = nil
        status = L("video_clip_preparing")
        let yt = youtube, maxHeight = height
        Task {
            do {
                guard let streams = try await yt.videoStreams(videoId: clip.videoId) else { throw VideoClipError(L("video_clip_none")) }
                let chosen = streams.videos.first { $0.height <= maxHeight } ?? streams.videos.last!
                let label = "\(chosen.height)p"
                await set(String(format: L("video_clip_downloading"), label), 0)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip_\(clip.videoId)", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let videoFile = dir.appendingPathComponent("v.mp4"), audioFile = dir.appendingPathComponent("a.m4a")
                try await fetch(chosen.url, to: videoFile, ua: streams.userAgent) { p in self.progressUpdate(p * 0.85) }
                try await fetch(streams.audio, to: audioFile, ua: streams.userAgent) { p in self.progressUpdate(0.85 + p * 0.15) }
                await set(L("video_clip_joining"), nil)
                let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
                let out = dir.appendingPathComponent(String(safe.prefix(100)) + ".mp4")
                try await mux(video: videoFile, audio: audioFile, to: out)
                try await saveToPhotos(out)
                try? FileManager.default.removeItem(at: dir)
                await MainActor.run {
                    busy = false
                    progress = nil
                    status = "✓ " + L("ios_video_saved_photos")
                }
            } catch {
                await MainActor.run {
                    busy = false
                    progress = nil
                    status = String(format: L("video_clip_failed"), (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    @MainActor private func set(_ text: String, _ p: Double?) {
        status = text
        progress = p
    }

    private func progressUpdate(_ p: Double) {
        DispatchQueue.main.async { self.progress = p }
    }

    /// Скачивание кусками по 10 МиБ (YouTube режет скорость цельных запросов).
    private func fetch(_ url: URL, to file: URL, ua: String, progress: @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = 10 * 1024 * 1024
        var offset = 0
        var total: Int?
        while total == nil || offset < total! {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let r = try await HTTP.send(req, session: .shared)
            let data = r.data
            guard r.status == 206 || r.status == 200 else { throw VideoClipError("HTTP \(r.status)") }
            if total == nil {
                if let range = r.header("Content-Range"), let t = range.split(separator: "/").last.flatMap({ Int($0) }) {
                    total = t
                } else {
                    total = data.count
                }
            }
            if data.isEmpty { break }
            handle.write(data)
            offset += data.count
            progress(Double(offset) / Double(max(1, total ?? offset)))
            if r.status == 200 { break }
        }
    }

    /// Картинка + звук в один MP4 без перекодирования.
    private func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = v.tracks(withMediaType: .video).first, let at = a.tracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoClipError(L("ai_error_unknown"))
        }
        let range = CMTimeRange(start: .zero, duration: v.duration)
        try cv.insertTimeRange(range, of: vt, at: .zero)
        cv.preferredTransform = vt.preferredTransform
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(a.duration, v.duration)), of: at, at: .zero)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoClipError(L("ai_error_unknown"))
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        if export.status != .completed { throw export.error ?? VideoClipError(L("ai_error_unknown")) }
    }

    private func saveToPhotos(_ file: URL) async throws {
        let status: PHAuthorizationStatus = await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { throw VideoClipError(L("ios_photos_denied")) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }) { ok, error in
                if ok { c.resume() } else { c.resume(throwing: error ?? VideoClipError(L("ai_error_unknown"))) }
            }
        }
    }
}

struct VideoClipError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
