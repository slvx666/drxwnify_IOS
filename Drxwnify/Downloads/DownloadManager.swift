import Foundation
import Combine
import GRDB

/// Скачивание треков для офлайна (DL-001, DL-002, DL-009, DL-011).
/// Файлы лежат в `Application Support/downloads`, учёт — в `downloads.json` и в `song` (`isDownloaded`, `dateDownload`, `localPath`).
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case queued
        case resolving
        case downloading(Double)
        case done
        case failed(String)
    }

    struct Item: Codable {
        var file: String
        var provider: String
        var bitrate: Int
        var codecs: String
        var bytes: Int
        var date: Double
        var track: Track
    }

    /// Состояние по `Track.id`. Скачанные треки тоже здесь (`.done`).
    @Published private(set) var states: [String: State] = [:]
    /// Растёт при каждом завершении или удалении: экраны перечитывают список скачанного.
    @Published private(set) var revision = 0

    /// Не скачавшийся трек и понятная причина («Почему не скачались», DL-008).
    struct Failure: Identifiable {
        var id: String { track.id }
        let track: Track
        let reason: String
    }

    /// Неудачи этого запуска по `Track.id`, в порядке появления.
    @Published private(set) var failures: [Failure] = []

    /// Повторить все неудачные загрузки.
    func retryFailed() {
        let tracks = failures.map { $0.track }
        failures.removeAll()
        download(tracks)
    }

    func clearFailures() { failures.removeAll() }

    private let engine: AudioFallbackEngine
    private let database: AppDatabase
    private var items: [String: Item] = [:]
    private var queue: [Track] = []
    private var running: [String: Task<Void, Never>] = [:]
    private let maxParallel = 2

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { folder.appendingPathComponent("downloads.json") }

    init(engine: AudioFallbackEngine, database: AppDatabase) {
        self.engine = engine
        self.database = database
        if let data = try? Data(contentsOf: Self.indexURL), let saved = try? JSONDecoder().decode([String: Item].self, from: data) {
            // Файл могли удалить снаружи — такие записи отбрасываются.
            items = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.value.file).path) }
            for id in items.keys { states[id] = .done }
        }
    }

    // MARK: - Чтение

    func isDownloaded(_ id: String) -> Bool { items[id] != nil }

    func item(_ id: String) -> Item? { items[id] }

    func fileURL(_ id: String) -> URL? {
        guard let item = items[id] else { return nil }
        let url = Self.folder.appendingPathComponent(item.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Скачанные треки, новые первыми.
    func downloadedTracks() -> [Track] {
        items.values.sorted { $0.date > $1.date }.map { $0.track }
    }

    var totalBytes: Int { items.values.reduce(0) { $0 + $1.bytes } }

    var activeCount: Int { queue.count + running.count }

    // MARK: - Очередь

    func download(_ tracks: [Track]) {
        for t in tracks where items[t.id] == nil && running[t.id] == nil && !queue.contains(where: { $0.id == t.id }) {
            failures.removeAll { $0.id == t.id }
            queue.append(t)
            states[t.id] = .queued
        }
        pump()
    }

    /// Отмена без удаления уже скачанного (DL-009).
    func cancel(_ id: String) {
        queue.removeAll { $0.id == id }
        running[id]?.cancel()
        running[id] = nil
        if items[id] == nil { states[id] = nil }
        pump()
    }

    func cancelAll() {
        let ids = queue.map { $0.id } + Array(running.keys)
        queue.removeAll()
        for id in ids { cancel(id) }
    }

    func remove(_ ids: [String]) {
        for id in ids {
            cancel(id)
            if let item = items[id] { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(item.file)) }
            items[id] = nil
            states[id] = nil
        }
        saveIndex()
        let db = database
        DispatchQueue.global(qos: .utility).async {
            try? db.pool.write { d in
                for id in ids {
                    try d.execute(sql: "UPDATE song SET isDownloaded = 0, dateDownload = NULL, localPath = NULL WHERE id = ?", arguments: [id])
                }
            }
        }
        revision += 1
    }

    func removeAll() { remove(Array(items.keys)) }

    private func pump() {
        while running.count < maxParallel, !queue.isEmpty {
            let track = queue.removeFirst()
            states[track.id] = .resolving
            running[track.id] = Task { [weak self] in
                await self?.run(track)
            }
        }
    }

    // MARK: - Скачивание одного трека

    private func run(_ track: Track) async {
        do {
            let audio = try await engine.stream(for: track.audioQuery)
            try Task.checkCancellation()
            let ext = audio.stream.mimeType.contains("mpeg") ? "mp3" : (audio.stream.mimeType.contains("flac") ? "flac" : "m4a")
            let name = Self.fileName(track) + "." + ext
            let target = Self.folder.appendingPathComponent(name)
            let temp = Self.folder.appendingPathComponent(name + ".part")
            try? FileManager.default.removeItem(at: temp)
            let id = track.id
            let bytes: Int
            if audio.stream.isHLS {
                bytes = try await HLSDownloader.download(audio.stream.url, headers: audio.stream.headers, to: temp) { [weak self] p in
                    DispatchQueue.main.async { if self?.running[id] != nil { self?.states[id] = .downloading(p) } }
                }
            } else {
                bytes = try await FileDownloader.download(audio.stream.url, headers: audio.stream.headers, to: temp) { [weak self] p in
                    DispatchQueue.main.async { if self?.running[id] != nil { self?.states[id] = .downloading(p) } }
                }
            }
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            let seconds = max(1, track.durationMs / 1000)
            let item = Item(file: name, provider: audio.match.provider.rawValue,
                            bitrate: audio.stream.bitrate > 0 ? audio.stream.bitrate : bytes * 8 / seconds,
                            codecs: audio.stream.codecs, bytes: bytes, date: Date().timeIntervalSince1970, track: track)
            await MainActor.run { self.finished(track, item) }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let message = Self.reason(error)
            await MainActor.run {
                self.running[track.id] = nil
                if !cancelled {
                    self.states[track.id] = .failed(message)
                    self.failures.removeAll { $0.id == track.id }
                    self.failures.append(Failure(track: track, reason: message))
                }
                self.pump()
            }
        }
    }

    private func finished(_ track: Track, _ item: Item) {
        running[track.id] = nil
        items[track.id] = item
        states[track.id] = .done
        saveIndex()
        revision += 1
        let db = database
        let path = Self.folder.appendingPathComponent(item.file).path
        DispatchQueue.global(qos: .utility).async {
            try? db.pool.write { d in
                try SongStore.ensure(d, track)
                try d.execute(sql: "UPDATE song SET isDownloaded = 1, dateDownload = ?, localPath = ? WHERE id = ?",
                              arguments: [SongStore.nowMs(), path, track.id])
            }
        }
        pump()
    }

    private func saveIndex() {
        let snapshot = items
        let url = Self.indexURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Имя файла «Артист - Название [id]» без запрещённых символов.
    private static func fileName(_ t: Track) -> String {
        let raw = "\(t.artistNames) - \(t.title)"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var clean = raw.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if clean.count > 80 { clean = String(clean.prefix(80)) }
        var h: UInt64 = 1469598103934665603
        for b in t.id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return clean + " [" + String(h, radix: 36) + "]"
    }
}

/// Загрузка обычного файла с прогрессом (iOS 14: без `URLSession.download(for:)`).
enum FileDownloader {
    private final class Delegate: NSObject, URLSessionDownloadDelegate {
        let target: URL
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<Int, Error>?
        var status = 0

        init(target: URL, progress: @escaping (Double) -> Void) {
            self.target = target
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: location, to: target)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { session.finishTasksAndInvalidate() }
            if let error = error {
                continuation?.resume(throwing: error)
            } else if !(200...299).contains(status) {
                continuation?.resume(throwing: URLError(.badServerResponse))
            } else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                continuation?.resume(returning: size)
            }
            continuation = nil
        }
    }

    static func download(_ url: URL, headers: [String: String], to target: URL, progress: @escaping (Double) -> Void) async throws -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let delegate = Delegate(target: target, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Загрузка HLS в один файл: сегмент инициализации и фрагменты склеиваются подряд (fMP4 → играемый .m4a, MP3 → .mp3).
enum HLSDownloader {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func download(_ playlist: URL, headers: [String: String], to target: URL, progress: @escaping (Double) -> Void) async throws -> Int {
        var text = try await fetchText(playlist, headers)
        var base = playlist
        // Мастер-плейлист: берём первый вариант.
        if text.contains("#EXT-X-STREAM-INF") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let variant = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }), let u = URL(string: variant, relativeTo: base) else {
                throw Failure(message: "HLS: no variant")
            }
            base = u.absoluteURL
            text = try await fetchText(base, headers)
        }
        if text.contains("#EXT-X-KEY") && !text.contains("METHOD=NONE") { throw Failure(message: "HLS: encrypted stream") }
        var urls: [URL] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let r = line.range(of: "URI=\"") {
                let uri = String(line[r.upperBound...].prefix { $0 != "\"" })
                if let u = URL(string: uri, relativeTo: base) { urls.append(u.absoluteURL) }
            } else if !line.isEmpty && !line.hasPrefix("#"), let u = URL(string: line, relativeTo: base) {
                urls.append(u.absoluteURL)
            }
        }
        guard !urls.isEmpty else { throw Failure(message: "HLS: empty playlist") }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var total = 0
        for (i, u) in urls.enumerated() {
            try Task.checkCancellation()
            let r = try await HTTP.get(u, headers: headers, timeout: 30)
            guard r.isSuccess else { throw Failure(message: "HLS: segment HTTP \(r.status)") }
            handle.write(r.data)
            total += r.data.count
            progress(Double(i + 1) / Double(urls.count))
        }
        return total
    }

    private static func fetchText(_ url: URL, _ headers: [String: String]) async throws -> String {
        let r = try await HTTP.get(url, headers: headers, timeout: 15)
        guard r.isSuccess else { throw Failure(message: "HLS: HTTP \(r.status)") }
        return r.text
    }
}

extension DownloadManager {
    /// Причина неудачи словами Android (`download_issue_*`): YouTube/VK ограничили запросы — смени сервер VPN;
    /// трека нет в источниках; иначе текст ошибки.
    static func reason(_ error: Error) -> String {
        let explained = PlaybackTrouble.explain(error)
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if explained != error.localizedDescription { return explained }
        if case AudioResolveError.notFound? = error as? AudioResolveError { return L("download_issue_not_found") }
        return raw
    }
}

