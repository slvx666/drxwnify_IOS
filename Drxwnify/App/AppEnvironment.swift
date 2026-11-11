import Foundation
import Combine

/// Единая точка зависимостей приложения. Передаётся через `EnvironmentObject`.
final class AppEnvironment: ObservableObject {
    let prefs: Prefs
    let database: AppDatabase
    let backup: BackupManager
    let player: PlayerController
    let spotifyTokens: SpotifyTokenManager
    let spotifyHashes: SpotifyHashes
    let spotify: SpotifyAPI
    let audio: AudioFallbackEngine
    let vk: VkProvider
    let likes: LikeManager
    /// Экран, который надо открыть поверх всего (ссылка, «перейти к альбому» из плеера).
    @Published var linkTarget: AppLinks.Target?

    init() {
        prefs = Prefs()
        database = Self.openDatabase()
        backup = BackupManager(prefs: prefs, database: database)
        vk = VkProvider(settings: prefs.settings)
        audio = AudioFallbackEngine(database: database, settings: prefs.settings,
                                    providers: [SoundCloudProvider(settings: prefs.settings), YouTubeProvider(), vk, LosslessProvider(), BandcampProvider(), AudiusProvider()])
        player = PlayerController(engine: audio, database: database, settings: prefs.settings)
        spotifyTokens = SpotifyTokenManager(settings: prefs.settings)
        spotifyHashes = SpotifyHashes(settings: prefs.settings)
        spotify = SpotifyAPI(tokens: spotifyTokens, hashes: spotifyHashes)
        likes = LikeManager(database: database, settings: prefs.settings, spotify: spotify)
        // Свежие GQL-хеши при каждом запуске (INT-006).
        let hashes = spotifyHashes
        Task.detached { await hashes.sync() }
        Task.detached { await RemoteConfig.shared.refreshIfNeeded() }
    }

    /// Открывает базу; повреждённый файл откладывает в сторону и создаёт новый.
    private static func openDatabase() -> AppDatabase {
        if let db = try? AppDatabase() { return db }
        let url = AppDatabase.defaultURL
        let fm = FileManager.default
        let broken = url.deletingLastPathComponent().appendingPathComponent("song.broken.db")
        try? fm.removeItem(at: broken)
        try? fm.moveItem(at: url, to: broken)
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        do {
            return try AppDatabase()
        } catch {
            fatalError("Не удалось создать базу: \(error)")
        }
    }
}
