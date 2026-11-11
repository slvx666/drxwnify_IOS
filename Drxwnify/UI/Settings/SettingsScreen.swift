import SwiftUI
import Nuke

/// Корень настроек: группы и порядок как `ui/screens/settings/SettingsScreen.kt` на Android.
/// Аккаунты и источники — на экране «Интеграции» (значок пазла в шапке, как на Android).
struct SettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section(header: Text(L("settings_section_ui"))) {
                settingsLink(L("appearance"), "paintpalette", AppearanceSettingsScreen(settings: env.prefs.settings))
            }
            Section(header: Text(L("settings_section_player_content"))) {
                settingsLink(L("player_and_audio"), "play", PlayerSettingsScreen(settings: env.prefs.settings))
                settingsLink(L("content"), "globe", ContentSettingsScreen(settings: env.prefs.settings))
            }
            Section(header: Text(L("settings_section_privacy"))) {
                settingsLink(L("privacy"), "lock.shield", PrivacySettingsScreen(settings: env.prefs.settings))
                settingsLink(L("settings_messages"), "text.bubble", MessagesSettingsScreen(chat: env.prefs.shared("chat")))
            }
            Section(header: Text(L("settings_section_storage"))) {
                settingsLink(L("storage"), "internaldrive", StorageSettingsScreen())
                settingsLink(L("backup_restore"), "externaldrive", BackupScreen())
            }
            Section(header: Text(L("settings_section_system"))) {
                settingsLink(L("integrations"), "puzzlepiece", IntegrationsScreen(settings: env.prefs.settings))
                settingsLink(L("app_update_title"), "arrow.down.app", AboutScreen())
                settingsLink(L("suggest_title"), "lightbulb", SuggestionsScreen())
                settingsLink(L("about"), "info.circle", AboutScreen())
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("settings"))
    }
}

/// Строка-переход настроек со значком в плашке, как на Android.
func settingsLink<D: View>(_ title: String, _ symbol: String, _ destination: D, subtitle: String? = nil) -> some View {
    NavigationLink(destination: destination) {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let s = subtitle, !s.isEmpty { Text(s).font(.caption).foregroundColor(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Переключатель, привязанный к ключу настроек Android.
struct PrefToggle: View {
    let title: String
    var subtitle: String?
    let key: PrefKey<Bool>
    let defaultValue: Bool
    @ObservedObject var settings: TypedStore

    var body: some View {
        Toggle(isOn: Binding(get: { settings.get(key) ?? defaultValue }, set: { settings.set(key, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle = subtitle { Text(subtitle).font(.caption).foregroundColor(.secondary) }
            }
        }
    }
}

/// Выбор из списка для строкового ключа (значения — как в enum Android).
struct PrefChoice: View {
    let title: String
    let key: PrefKey<String>
    let defaultValue: String
    let options: [(String, String)]
    @ObservedObject var settings: TypedStore

    var body: some View {
        Picker(selection: Binding(get: { settings.get(key) ?? defaultValue }, set: { settings.set(key, $0) }), label: Text(title)) {
            ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
        }
    }
}

// MARK: - Внешний вид

struct AppearanceSettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore

    var body: some View {
        List {
            Section(header: Text(L("app_theme_title"))) {
                ForEach(AppTheme.allCases) { theme in
                    Button(action: { env.setTheme(theme) }) {
                        HStack(spacing: 12) {
                            Circle().fill(theme.accent ?? Color.accentColor).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(theme.titleKey)).foregroundColor(.primary)
                                Text(L(theme.descriptionKey)).font(.caption).foregroundColor(.secondary).lineLimit(3)
                            }
                            Spacer()
                            if AppTheme.current == theme { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                }
            }
            Section(header: Text(L("app_language"))) {
                ForEach([AppLanguage.systemDefault, "ru", "en"], id: \.self) { code in
                    Button(action: { env.setLanguage(code) }) {
                        HStack {
                            Text(code == AppLanguage.systemDefault ? L("system_default") : (code == "ru" ? "Русский" : "English"))
                                .foregroundColor(.primary)
                            Spacer()
                            if (AppLanguage.code ?? AppLanguage.systemDefault) == code {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            Section(header: Text(L("player"))) {
                PrefToggle(title: L("keep_screen_on_when_player_is_expanded"), key: PK.keepScreenOn, defaultValue: false, settings: settings)
            }
            Section(header: Text(L("lyrics"))) {
                PrefChoice(title: L("lyrics_text_position"), key: PK.lyricsTextPosition, defaultValue: "CENTER",
                           options: [("LEFT", L("left")), ("CENTER", L("center")), ("RIGHT", L("right"))], settings: settings)
                Stepper(value: Binding(get: { Int(settings.get(PK.lyricsTextSize) ?? 24) },
                                       set: { settings.set(PK.lyricsTextSize, Float($0)) }), in: 14...36) {
                    HStack {
                        Text(L("lyrics_text_size"))
                        Spacer()
                        Text("\(Int(settings.get(PK.lyricsTextSize) ?? 24))").foregroundColor(.secondary)
                    }
                }
                PrefToggle(title: L("lyrics_click_change"), key: PK.lyricsClick, defaultValue: true, settings: settings)
                PrefToggle(title: L("lyrics_auto_scroll"), key: PK.lyricsScrollKey, defaultValue: true, settings: settings)
            }
            Section(header: Text(L("misc"))) {
                PrefChoice(title: L("default_open_tab"), key: PK.defaultOpenTab, defaultValue: "HOME",
                           options: [("HOME", L("home")), ("EXPLORE", L("search")), ("LIBRARY", L("filter_library"))], settings: settings)
                PrefToggle(title: L("show_liked_playlist"), key: PK.showLikedPlaylist, defaultValue: true, settings: settings)
                PrefToggle(title: L("show_downloaded_playlist"), key: PK.showDownloadedPlaylist, defaultValue: true, settings: settings)
                PrefToggle(title: L("show_top_playlist"), key: PK.showTopPlaylist, defaultValue: true, settings: settings)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("appearance"))
    }
}

// MARK: - Плеер и аудио

struct PlayerSettingsScreen: View {
    @ObservedObject var settings: TypedStore
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        List {
            Section(header: Text(L("player"))) {
                NavigationLink(destination: MusicSourcesScreen()) { Text(L("music_sources")) }
                Stepper(value: Binding(get: { Int(settings.get(PK.historyDuration) ?? 30) },
                                       set: { settings.set(PK.historyDuration, Float($0)) }), in: 5...240, step: 5) {
                    HStack {
                        Text(L("history_duration"))
                        Spacer()
                        Text("\(Int(settings.get(PK.historyDuration) ?? 30)) s").foregroundColor(.secondary)
                    }
                }
                Toggle(L("varispeed"), isOn: Binding(get: { player.pitchFollowsRate }, set: { player.setPitchFollowsRate($0) }))
            }
            Section(header: Text(L("sleep_timer"))) {
                Stepper(value: Binding(get: { Int(settings.get(PK.sleepTimerDefault) ?? 30) },
                                       set: { settings.set(PK.sleepTimerDefault, Float($0)) }), in: 5...180, step: 5) {
                    HStack {
                        Text(L("sleep_timer"))
                        Spacer()
                        Text("\(Int(settings.get(PK.sleepTimerDefault) ?? 30)) min").foregroundColor(.secondary)
                    }
                }
                PrefToggle(title: L("end_of_song"), key: PK.sleepTimerStopAfterCurrentSong, defaultValue: false, settings: settings)
                PrefToggle(title: L("fade"), key: PK.sleepTimerFadeOut, defaultValue: false, settings: settings)
                PrefToggle(title: L("ios_auto_sleep"), subtitle: L("sleep_timer_repeat_description"), key: PK.sleepTimerEnabled, defaultValue: false, settings: settings)
                if settings.get(PK.sleepTimerEnabled) ?? false {
                    PrefChoice(title: L("sleep_timer_repeat"), key: PK.sleepTimerRepeat, defaultValue: "daily",
                               options: [("daily", L("sleep_timer_daily")), ("weekdays", L("sleep_timer_weekdays")), ("weekends", L("sleep_timer_weekends"))],
                               settings: settings)
                    TimePrefRow(title: L("sleep_timer_start_time"), key: PK.sleepTimerStartTime, fallback: "22:00", settings: settings)
                    TimePrefRow(title: L("sleep_timer_end_time"), key: PK.sleepTimerEndTime, fallback: "06:00", settings: settings)
                }
            }
            Section(header: Text(L("queue"))) {
                PrefToggle(title: L("persistent_queue"), subtitle: L("persistent_queue_desc"), key: PK.persistentQueue, defaultValue: true, settings: settings)
                PrefToggle(title: L("auto_load_more"), subtitle: L("auto_load_more_desc"), key: PK.autoLoadMore, defaultValue: true, settings: settings)
                PrefToggle(title: L("disable_load_more_when_repeat_all"), subtitle: L("disable_load_more_when_repeat_all_desc"),
                           key: PK.disableLoadMoreWhenRepeatAll, defaultValue: false, settings: settings)
                PrefToggle(title: L("ios_auto_download_like"), key: PK.autoDownloadOnLike, defaultValue: false, settings: settings)
                PrefToggle(title: L("remember_shuffle_and_repeat"), key: PK.rememberShuffleAndRepeat, defaultValue: true, settings: settings)
                PrefToggle(title: L("prevent_duplicate_tracks_in_queue"), key: PK.preventDuplicateTracksInQueue, defaultValue: false, settings: settings)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("player_and_audio"))
    }
}

// MARK: - Контент

struct ContentSettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore

    var body: some View {
        List {
            Section(header: Text(L("general"))) {
                PrefToggle(title: L("hide_explicit"), key: PK.hideExplicit, defaultValue: false, settings: settings)
            }
            Section(header: Text(L("ios_artist"))) {
                PrefToggle(title: L("show_artist_description"), key: PK.showArtistDescription, defaultValue: true, settings: settings)
                PrefToggle(title: L("show_artist_subscriber_count"), key: PK.showArtistSubscriberCount, defaultValue: true, settings: settings)
                PrefToggle(title: L("show_artist_monthly_listeners"), key: PK.showMonthlyListeners, defaultValue: true, settings: settings)
            }
            Section(header: Text(L("lyrics"))) {
                NavigationLink(destination: LyricsSettingsScreen(settings: settings)) { Text(L("lyrics")) }
            }
            Section(header: Text(L("misc"))) {
                PrefToggle(title: L("randomize_home_order"), key: PK.randomizeHomeOrder, defaultValue: false, settings: settings)
                PrefChoice(title: L("top_length"), key: PK.topSize, defaultValue: "50",
                           options: ["10", "20", "50", "100"].map { ($0, $0) }, settings: settings)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("content"))
    }
}

// MARK: - Интеграции (Android: `settings/integrations`)

struct IntegrationsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @State private var showSpotifyLogin = false
    @State private var showYandexLogin = false
    @State private var confirmLogout = false

    private var spotifyLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty }
    private var yandexLinked: Bool { !(settings.get(PK.yandexAccessToken) ?? "").isEmpty }
    private var vkLinked: Bool { !(settings.get(PK.vkAccessToken) ?? "").isEmpty }

    var body: some View {
        List {
            Section(header: Text(L("general"))) {
                settingsLink(L("music_sources"), "antenna.radiowaves.left.and.right", MusicSourcesScreen(),
                             subtitle: L("ios_integrations_sources_desc"))
            }
            Section(header: Text("Spotify")) {
                if spotifyLinked {
                    HStack {
                        Label("Spotify", systemImage: "checkmark.circle.fill")
                        Spacer()
                        Text(settings.get(PK.spotifyUsername) ?? "").foregroundColor(.secondary).lineLimit(1)
                    }
                    PrefToggle(title: L("spotify_sync_likes"), key: PK.spotifySyncLikes, defaultValue: true, settings: settings)
                    Button(L("action_logout")) { confirmLogout = true }.foregroundColor(.red)
                } else {
                    Button(action: { showSpotifyLogin = true }) { Label(L("spotify_login"), systemImage: "music.note") }
                }
            }
            Section(header: Text(L("yandex_music"))) {
                if yandexLinked {
                    HStack {
                        Label(L("yandex_music"), systemImage: "checkmark.circle.fill")
                        Spacer()
                        Text(settings.get(PK.yandexUsername) ?? "").foregroundColor(.secondary).lineLimit(1)
                    }
                    Button(L("ios_yandex_logout")) {
                        settings.set(PK.yandexAccessToken, nil)
                        settings.set(PK.yandexUid, nil)
                        settings.set(PK.yandexUsername, nil)
                        env.spotify.yandex?.logout()
                    }
                    .foregroundColor(.red)
                } else {
                    Button(action: { showYandexLogin = true }) { Label(L("yandex_login"), systemImage: "y.circle") }
                }
            }
            if spotifyLinked && yandexLinked {
                Section(header: Text(L("ios_primary_source")), footer: Text(L("ios_primary_source_hint"))) {
                    Picker(L("ios_primary_source"), selection: Binding(get: { settings.get(PK.primaryMetadataSource) ?? "SPOTIFY" },
                                                                      set: { settings.set(PK.primaryMetadataSource, $0) })) {
                        Text("Spotify").tag("SPOTIFY")
                        Text(L("yandex_music")).tag("YANDEX")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
            }
            Section(header: Text(L("vk_music"))) {
                if vkLinked {
                    HStack {
                        Label(L("vk_music"), systemImage: "checkmark.circle.fill")
                        Spacer()
                        Text(L("vk_connected")).foregroundColor(.secondary).lineLimit(1)
                    }
                    Button(L("ios_vk_logout")) {
                        settings.set(PK.vkAccessToken, nil)
                        settings.set(PK.vkUserId, nil)
                    }
                    .foregroundColor(.red)
                } else {
                    NavigationLink(destination: VkLoginScreen()) { Label(L("vk_login"), systemImage: "person.crop.circle.badge.plus") }
                }
            }
            Section(header: Text("SoundCloud")) {
                settingsLink(L("soundcloud_import"), "cloud", SoundCloudImportScreen(), subtitle: L("ios_soundcloud_import_desc"))
                settingsLink(L("import_playlist"), "square.and.arrow.down.on.square", ImportPlaylistScreen())
            }
            Section(header: Text("Last.fm")) {
                settingsLink("Last.fm", "dot.radiowaves.up.forward", LastFMSettingsScreen(settings: settings),
                             subtitle: settings.get(PK.lastfmUsername) ?? L("ios_lastfm_genres_desc"))
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("integrations"))
        .background(EmptyView().sheet(isPresented: $showYandexLogin) {
            YandexLoginScreen().environmentObject(env)
        })
        .sheet(isPresented: $showSpotifyLogin) {
            SpotifyLoginScreen().environmentObject(env)
        }
        .alert(isPresented: $confirmLogout) {
            Alert(
                title: Text(L("ios_spotify_logout_confirm")),
                primaryButton: .destructive(Text(L("action_logout"))) {
                    let tokens = env.spotifyTokens
                    Task { await tokens.logout() }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

// MARK: - Конфиденциальность

struct PrivacySettingsScreen: View {
    @ObservedObject var settings: TypedStore
    @EnvironmentObject private var friends: FriendsHub

    var body: some View {
        List {
            Section {
                PrefToggle(title: L("pause_listen_history"), key: PK.pauseListenHistory, defaultValue: false, settings: settings)
                PrefToggle(title: L("pause_search_history"), key: PK.pauseSearchHistory, defaultValue: false, settings: settings)
            }
            if friends.hasProfile {
                Section(header: Text(L("friends_title"))) {
                    NavigationLink(destination: MyProfileScreen()) { Text(L("ios_friends_my_profile")) }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("privacy"))
    }
}

// MARK: - Сообщения (Android: `settings/messages`, SharedPreferences `chat`)

struct MessagesSettingsScreen: View {
    @ObservedObject var chat: TypedStore
    static let reactions = ["❤️", "👍", "🔥", "😂", "😭", "😍", "🤯", "👎", "😢", "😮", "😡", "🤔", "👏", "🎉", "💯", "🙏", "👀"]

    var body: some View {
        List {
            Section(header: Text(L("chat_quick_reaction")), footer: Text(L("settings_messages_quick_desc"))) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                    ForEach(Self.reactions, id: \.self) { e in
                        Button(action: { chat.setString("e:" + e, for: "quickReaction") }) {
                            Text(e).font(.system(size: 28))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(MessagesSettingsScreen.quick(chat) == e ? Color.accentColor.opacity(0.35) : Color.clear))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Toggle(L("chat_notify"), isOn: Binding(get: { chat.bool("notify") ?? true }, set: { chat.setBool($0, for: "notify") }))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("settings_messages"))
    }

    /// Эмодзи быстрой реакции (ключ `e:<эмодзи>`, как `ChatReactions.quick` на Android).
    static func quick(_ chat: TypedStore) -> String {
        if let k = chat.string("quickReaction"), k.hasPrefix("e:") { return String(k.dropFirst(2)) }
        return "❤️"
    }
}

// MARK: - Хранилище

struct StorageSettingsScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var env: AppEnvironment
    private var settings: TypedStore { env.prefs.settings }
    @State private var confirmClear = false
    @State private var imageBytes = 0

    var body: some View {
        List {
            Section(header: Text(L("downloaded_songs"))) {
                HStack {
                    Text(L("downloaded_songs"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(downloads.totalBytes), countStyle: .file)).foregroundColor(.secondary)
                }
                PrefToggle(title: L("ios_auto_download_like"), key: PK.autoDownloadOnLike, defaultValue: false, settings: settings)
                Button(L("clear_all_downloads")) { confirmClear = true }
                    .foregroundColor(.red)
                    .disabled(downloads.totalBytes == 0)
            }
            Section(header: Text(L("image_cache"))) {
                HStack {
                    Text(L("image_cache"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(imageBytes), countStyle: .file)).foregroundColor(.secondary)
                }
                Button(L("clear_image_cache")) {
                    ImagePipeline.shared.cache.removeAll()
                    (ImagePipeline.shared.configuration.dataCache as? DataCache)?.removeAll()
                    URLCache.shared.removeAllCachedResponses()
                    imageBytes = 0
                }
                .foregroundColor(.red)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("storage"))
        .onAppear {
            imageBytes = ((ImagePipeline.shared.configuration.dataCache as? DataCache)?.totalSize ?? 0) + URLCache.shared.currentDiskUsage
        }
        .alert(isPresented: $confirmClear) {
            Alert(title: Text(L("clear_all_downloads")),
                  primaryButton: .destructive(Text(L("ios_delete"))) { downloads.removeAll() },
                  secondaryButton: .cancel())
        }
    }
}

// MARK: - О приложении и обновления

struct AboutScreen: View {
    @StateObject private var checker = UpdateChecker()

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Drxwnify")
                    Spacer()
                    Text(version).foregroundColor(.secondary)
                }
            }
            Section(header: Text(L("app_update_title"))) {
                switch checker.state {
                case .idle, .checking:
                    HStack { Text(L("ios_update_checking")); Spacer(); ProgressView() }
                case .upToDate:
                    Text(L("ios_update_latest"))
                case .available(let tag, let url):
                    Button(action: { UIApplication.shared.open(url) }) {
                        Label(L("ios_update_available", tag), systemImage: "arrow.down.circle.fill")
                    }
                case .failed:
                    Button(L("retry")) { checker.check() }
                }
            }
            Section {
                Button(action: { UIApplication.shared.open(UpdateChecker.releasesPage) }) {
                    Label("GitHub", systemImage: "link")
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("about"))
        .onAppear { if case .idle = checker.state { checker.check() } }
    }
}

/// Проверка обновлений (SYS-3xx): на iOS нельзя ставить самим, поэтому — версия с GitHub и ссылка на релиз.
final class UpdateChecker: ObservableObject {
    enum State { case idle, checking, upToDate, available(String, URL), failed }

    static let releasesPage = URL(string: "https://github.com/slvx666/drxwnify_IOS/releases")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/slvx666/drxwnify_IOS/releases/latest")!

    @Published private(set) var state: State = .idle

    func check() {
        state = .checking
        var request = URLRequest(url: Self.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var next: State = .failed
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if Self.isNewer(remote, than: local) {
                    let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
                    next = .available(remote, page)
                } else {
                    next = .upToDate
                }
            }
            DispatchQueue.main.async { self?.state = next }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Last.fm

struct LastFMSettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            if !LastFM.isConfigured {
                Text(L("ios_lastfm_no_key")).foregroundColor(.secondary)
            } else if let name = settings.get(PK.lastfmUsername), !(settings.get(PK.lastfmSession) ?? "").isEmpty {
                Section {
                    HStack { Text(L("ios_account")); Spacer(); Text(name).foregroundColor(.secondary) }
                    Button(L("action_logout")) { env.lastfm.logout() }.foregroundColor(.red)
                }
                Section {
                    PrefToggle(title: L("ios_lastfm_scrobble"), key: PK.lastfmScrobblingEnable, defaultValue: true, settings: settings)
                    PrefToggle(title: L("ios_lastfm_now_playing"), key: PK.lastfmUseNowPlaying, defaultValue: true, settings: settings)
                    PrefToggle(title: L("ios_lastfm_send_likes"), key: PK.lastfmUseSendLikes, defaultValue: false, settings: settings)
                }
            } else {
                Section(footer: Text(error ?? L("ios_lastfm_login_hint")).foregroundColor(error == nil ? .secondary : .red)) {
                    TextField(L("ios_lastfm_username"), text: $username).autocapitalization(.none).disableAutocorrection(true)
                    SecureField(L("ios_lastfm_password"), text: $password)
                    Button(action: login) {
                        HStack { Text(L("ios_lastfm_login")); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(username.isEmpty || password.isEmpty || working)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("Last.fm")
    }

    private func login() {
        working = true
        error = nil
        let lf = env.lastfm, u = username, p = password
        Task {
            do {
                try await lf.login(username: u, password: p)
                await MainActor.run { working = false; password = "" }
            } catch {
                await MainActor.run { working = false; self.error = error.localizedDescription }
            }
        }
    }
}


/// Время «ЧЧ:ММ» в строковом ключе (формат Android).
struct TimePrefRow: View {
    let title: String
    let key: PrefKey<String>
    let fallback: String
    @ObservedObject var settings: TypedStore

    private var date: Binding<Date> {
        Binding(get: {
            let p = (settings.get(key) ?? fallback).split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: p.first ?? 22, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            settings.set(key, String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        })
    }

    var body: some View {
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
    }
}
