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
    let lastfm: LastFM
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
    /// Сколько открытых экранов прячут панель вкладок («Вместе», чат — как на Android).
    @Published var chromeHiders = 0
    var chromeHidden: Bool { chromeHiders > 0 }
    /// Открыть «Вместе» с главной (приглашение по ссылке, значок в шапке).
    @Published var showTogether = false
    /// Открытое меню трека (лист в `RootView`).
    @Published var trackMenu: TrackMenuRequest?
    /// Открытое выделение треков (лист в `RootView`).
    @Published var trackSelection: TrackBatch?

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
        spotify.settings = prefs.settings
        spotify.yandex = YandexAPI(settings: prefs.settings)
        likes = LikeManager(database: database, settings: prefs.settings, spotify: spotify)
        player.catalog = spotify
        BlockedTracks.shared.configure(prefs)
        lastfm = LastFM(settings: prefs.settings)
        library = LibraryStore(database: database)
        lyrics = LyricsStore(database: database)
        lyrics.settings = prefs.settings
        // Язык из настроек (в том числе из копии с Android) — до первого экрана.
        UserDefaults.standard.set(prefs.settings.get(PK.appLanguage) ?? AppLanguage.systemDefault, forKey: "appLanguage")
        UserDefaults.standard.set(prefs.settings.get(PK.appThemePreset) ?? AppTheme.standard.rawValue, forKey: "appThemePreset")
        AppTheme.current.applyAppearance()
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
        // Ответы разработчика на предложку — немного после запуска, когда релеи подключатся.
        Suggestions.shared.friends = friends
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Suggestions.shared.checkReplies() }
    }

    /// Меняется при смене языка: корень перерисовывается целиком.
    @Published private(set) var languageVersion = 0

    /// Тема (THEME-003): настройка `appThemePreset`, цвета UIKit, корень перерисовывается.
    func setTheme(_ theme: AppTheme) {
        prefs.settings.set(PK.appThemePreset, theme.rawValue)
        UserDefaults.standard.set(theme.rawValue, forKey: "appThemePreset")
        theme.applyAppearance()
        languageVersion += 1
    }

    func setLanguage(_ code: String) {
        prefs.settings.set(PK.appLanguage, code)
        UserDefaults.standard.set(code, forKey: "appLanguage")
        languageVersion += 1
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
        let lf = lastfm
        lf.attach(p)
        p.onListened = {
            let t = p.current
            DispatchQueue.main.async {
                f.listened()
                if let t = t { lf.scrobble(t) }
            }
        }
        let dl = downloads, st = prefs.settings
        likes.onLike = { t, on in
            lf.love(t, on)
            // DL-010: лайк — сразу скачать (настройка «Скачивать при лайке»).
            if on, st.get(PK.autoDownloadOnLike) ?? false { DispatchQueue.main.async { dl.download([t]) } }
        }
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
