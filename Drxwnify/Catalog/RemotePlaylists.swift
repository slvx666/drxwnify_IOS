import Foundation

/// Свои плейлисты приложения, создаваемые и в музыкальном аккаунте — медленно и в фоне (Android 2.3.0 `RemotePlaylists`).
/// Сначала плейлист живёт в приложении (играет сразу), потом такой же создаётся в основном аккаунте и наполняется пачками
/// с паузами. Задачи лежат на диске: шаги CREATE → FILL → DONE; id плейлиста в аккаунте сохраняется сразу после создания,
/// позиция — после каждой пачки, так что повтор не создаст второй плейлист и не добавит пачку дважды.
/// Ещё помнит, какие плейлисты пришли из импорта (файлы, ссылки, другой аккаунт): их предлагается создать в основном.
final class RemotePlaylists: ObservableObject {
    enum Step: String, Codable { case CREATE, FILL, DONE, FAILED }

    struct Job: Codable, Equatable {
        var localId: String
        var target: String
        var title: String
        var step: Step = .CREATE
        var remoteId: String?
        var cursor = 0
        var total = 0
        var missing: [String] = []
        var error: String?
    }

    static let shared = RemotePlaylists()

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var localImportCount = 0
    private weak var env: AppEnvironment?
    private var working = false
    private let importsKey = "imported_playlists"

    private static let batch = 20
    private static let lookupPause: UInt64 = 400_000_000
    private static let betweenBatches: UInt64 = 4_000_000_000
    private static let betweenJobs: UInt64 = 6_000_000_000

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("remote_playlists.json")
    }

    func configure(_ env: AppEnvironment) {
        self.env = env
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Job].self, from: d) { jobs = list }
        refreshImports()
        NotificationCenter.default.addObserver(forName: .mainAccountChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshImports() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.kick() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(jobs).write(to: file, options: .atomic)
    }

    // MARK: - Импортированные плейлисты

    func markImported(_ playlistId: String) {
        var set = UserDefaults.standard.stringArray(forKey: importsKey) ?? []
        if !set.contains(playlistId) { set.append(playlistId) }
        UserDefaults.standard.set(set, forKey: importsKey)
        refreshImports()
    }

    private func importedIds() -> [String] {
        guard let lib = env?.library else { return [] }
        let have = Set(lib.playlists().map { $0.id })
        return (UserDefaults.standard.stringArray(forKey: importsKey) ?? []).filter { have.contains($0) }
    }

    func isPushed(_ localId: String, _ target: CatalogSource) -> Bool {
        jobs.contains { $0.localId == localId && $0.target == target.rawValue && $0.step != .FAILED }
    }

    func refreshImports() {
        guard let main = MainAccount.shared.main, canCreate(main) else { localImportCount = 0; return }
        localImportCount = importedIds().filter { !isPushed($0, main) }.count
    }

    /// Создать в основном аккаунте все импортированные плейлисты, которых там ещё нет.
    func pushLocalImports(env: AppEnvironment) {
        guard let main = MainAccount.shared.main else { return }
        push(importedIds().filter { !isPushed($0, main) }, to: main)
    }

    // MARK: - Задачи

    func canCreate(_ target: CatalogSource) -> Bool {
        switch target {
        case .SPOTIFY, .YANDEX: return MainAccount.shared.isLinked(target)
        case .VK: return env?.vk.hasOwnAccount ?? false
        }
    }

    func push(_ localIds: [String], to target: CatalogSource) {
        guard let lib = env?.library else { return }
        let names = Dictionary(lib.playlists().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        jobs.removeAll { $0.target == target.rawValue && $0.step == .FAILED && localIds.contains($0.localId) }
        for id in localIds where !isPushed(id, target) {
            guard let name = names[id] else { continue }
            jobs.append(Job(localId: id, target: target.rawValue, title: name))
        }
        save()
        refreshImports()
        kick()
    }

    func clearFinished() {
        jobs.removeAll { $0.step == .DONE || $0.step == .FAILED }
        save()
    }

    private func kick() {
        guard !working, let env = env else { return }
        working = true
        Task {
            while true {
                let next: Job? = await MainActor.run { self.jobs.first { $0.step == .CREATE || $0.step == .FILL } }
                guard let job = next, let target = CatalogSource(rawValue: job.target), canCreate(target) else { break }
                do {
                    try await run(job, target: target, env: env)
                } catch {
                    await MainActor.run { self.update(job.localId, job.target) { $0.step = .FAILED; $0.error = error.localizedDescription } }
                }
                try? await Task.sleep(nanoseconds: Self.betweenJobs)
            }
            await MainActor.run {
                self.working = false
                self.refreshImports()
            }
        }
    }

    private func run(_ start: Job, target: CatalogSource, env: AppEnvironment) async throws {
        let api = env.spotify
        var job = start
        let tracks = await MainActor.run { env.library.playlistEntries(job.localId).map { $0.track } }
        if job.step == .CREATE {
            let remote = try await create(target, job.title, api: api)
            job.step = .FILL
            job.remoteId = remote
            job.total = tracks.count
            let j = job
            await MainActor.run { self.update(j.localId, j.target) { $0 = j } }
        }
        guard let remote = job.remoteId else { throw SpotifyError(statusCode: 500, message: "No playlist in the account") }
        var cursor = job.cursor
        var missing = job.missing
        while cursor < tracks.count {
            let part = tracks[cursor..<min(cursor + Self.batch, tracks.count)]
            var ids: [String] = []
            for t in part {
                var found = await CrossCatalog.trackFor(target, track: t, api: api)
                if found == nil, t.catalogId == nil { found = await Self.find(t, in: target, api: api) }
                if let found = found {
                    if !ids.contains(found) { ids.append(found) }
                } else {
                    missing.append([t.artists.first?.name, t.title].compactMap { $0 }.joined(separator: " – "))
                }
                try? await Task.sleep(nanoseconds: Self.lookupPause)
            }
            try await add(target, remote, ids, api: api)
            cursor += part.count
            let c = cursor, m = missing, total = tracks.count
            await MainActor.run { self.update(job.localId, job.target) { $0.cursor = c; $0.missing = m; $0.total = total } }
            try? await Task.sleep(nanoseconds: Self.betweenBatches)
        }
        let m = missing, total = tracks.count
        await MainActor.run { self.update(job.localId, job.target) { $0.step = .DONE; $0.cursor = total; $0.missing = m } }
    }

    /// Трек без id каталога (свой файл, YouTube) — поиском по названию.
    private static func find(_ t: Track, in target: CatalogSource, api: SpotifyAPI) async -> String? {
        let artist = t.artists.first?.name ?? ""
        guard let r = try? await api.searchIn(target, [artist, t.title].filter { !$0.isEmpty }.joined(separator: " "), limit: 10) else { return nil }
        return FuzzyTrackMatch.ranked(
            artist: artist.isEmpty ? nil : artist, title: t.title, durationSec: t.durationMs > 0 ? t.durationMs / 1000 : nil,
            candidates: r.tracks.map { FuzzyTrackMatch.Candidate(id: $0.id, title: $0.name, artists: $0.artists.map { $0.name },
                                                                  durationSec: $0.durationMs > 0 ? $0.durationMs / 1000 : nil) }).first?.id
    }

    private func create(_ target: CatalogSource, _ title: String, api: SpotifyAPI) async throws -> String {
        switch target {
        case .SPOTIFY: return try await api.createPlaylist(title)
        case .YANDEX:
            guard let y = api.yandex else { throw YandexError(status: 401, message: "Yandex") }
            return try await y.createPlaylist(title)
        case .VK:
            guard let v = api.vkCatalog else { throw VkProvider.ApiError(code: 401, message: "VK") }
            return try await v.createPlaylist(title)
        }
    }

    private func add(_ target: CatalogSource, _ playlistId: String, _ ids: [String], api: SpotifyAPI) async throws {
        guard !ids.isEmpty else { return }
        switch target {
        case .SPOTIFY: try await api.addTracksToPlaylist(playlistId, trackIds: ids)
        case .YANDEX: try await api.yandex?.addToPlaylist(playlistId, trackIds: ids)
        case .VK: try await api.vkCatalog?.addToPlaylist(playlistId, trackIds: ids)
        }
    }

    private func update(_ localId: String, _ target: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.localId == localId && $0.target == target }) else { return }
        change(&jobs[i])
        save()
    }
}
