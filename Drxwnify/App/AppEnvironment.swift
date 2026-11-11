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
    let library: LibraryStore
    let downloads: DownloadManager
    let lyrics: LyricsStore
    let friends: FriendsHub
    let chats: ChatHub
    private var bag = Set<AnyCancellable>()
    /// Треки для листа «Добавить в плейлист».
    @Published var addToPlaylist: TrackBatch?
    /// Экран, который надо открыть поверх всего (ссылка, «перейти к альбому» из плеера).
    @Published var linkTarget: AppLinks.Target?
    /// Экран без мини-плеера и панели вкладок (чат, как на Android).
    @Published var chromeHidden = false

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
        library = LibraryStore(database: database)
        lyrics = LyricsStore(database: database)
        friends = FriendsHub(prefs: prefs, database: database)
        chats = ChatHub(friends: friends, prefs: prefs)
        downloads = DownloadManager(engine: audio, database: database)
        let dl = downloads
        player.localAudio = { track in
            guard let url = dl.fileURL(track.id), let item = dl.item(track.id) else { return nil }
            let provider = AudioProviderId(rawValue: item.provider) ?? .SOUNDCLOUD
            return ResolvedAudio(
                match: ProviderMatch(provider: provider, trackId: "local", title: track.title, artist: track.artistNames,
                                     durationMs: track.durationMs, confidence: 1, thumbnailUrl: nil, qualityKbps: item.bitrate / 1000),
                stream: AudioStream(url: url, mimeType: "", codecs: item.codecs, bitrate: item.bitrate, expiresAt: .distantFuture),
                isLocal: true)
        }
        // Свежие GQL-хеши при каждом запуске (INT-006).
        let hashes = spotifyHashes
        Task.detached { await hashes.sync() }
        Task.detached { await RemoteConfig.shared.refreshIfNeeded() }
        wireFriends()
    }

    /// Что играет — друзьям (now, с задержкой 1,5 с), прослушивания — в историю друзей; «слушать вместе» ведёт плеер за другом.
    private func wireFriends() {
        let f = friends, p = player, c = chats
        Publishers.CombineLatest(p.$currentIndex, p.$isPlaying)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { _, playing in
                f.playerChanged(track: p.current, positionMs: Int64(p.position * 1000), playing: playing, durationMs: Int64(p.duration * 1000))
                c.hold("playing", playing)
            }
            .store(in: &bag)
        p.onListened = { DispatchQueue.main.async { f.listened() } }
        f.onFriendNow = { now in
            let wanted = now.track.track
            let position = Double(now.positionNow()) / 1000
            if p.current?.id != wanted.id {
                p.play([wanted], title: f.data[f.listeningTo ?? ""]?.name)
                if position > 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { p.seek(to: Double(now.positionNow()) / 1000) } }
            } else if abs(p.position - position) > 3 {
                // Расхождение больше 3 с — перемотка (`ListenAlong.kt:79`).
                p.seek(to: position)
            }
            if now.playing && !p.isPlaying { p.resume() }
            if !now.playing && p.isPlaying { p.pause() }
        }
    }

    /// После восстановления резервной копии: настройки друзей и чатов перечитываются.
    func reloadAfterRestore() {
        friends.load()
        chats.refresh()
        likes.reload()
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
