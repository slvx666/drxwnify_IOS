import SwiftUI

/// Корень настроек: группы и порядок как `ui/screens/settings/SettingsScreen.kt` на Android.
/// Внутри — только то, что iOS-версия уже умеет; остальное добавляется по этапу 13.
struct SettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        List {
            Section(header: Text(L("settings_section_ui"))) {
                settingsLink(L("appearance"), "paintpalette", AppearanceSettingsScreen())
            }
            Section(header: Text(L("settings_section_player_content"))) {
                settingsLink(L("player_and_audio"), "play", PlayerSettingsScreen(settings: env.prefs.settings))
                settingsLink(L("content"), "globe", ContentSettingsScreen(settings: env.prefs.settings))
                settingsLink(L("music_sources"), "antenna.radiowaves.left.and.right", MusicSourcesScreen())
            }
            Section(header: Text(L("settings_section_privacy"))) {
                settingsLink(L("privacy"), "lock.shield", PrivacySettingsScreen(settings: env.prefs.settings))
            }
            Section(header: Text(L("settings_section_storage"))) {
                settingsLink(L("storage"), "internaldrive", StorageSettingsScreen())
                settingsLink(L("backup_restore"), "externaldrive", BackupScreen())
            }
            Section(header: Text(L("settings_section_system"))) {
                settingsLink(L("app_update_title"), "arrow.down.app", AboutScreen())
                settingsLink(L("about"), "info.circle", AboutScreen())
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("settings"))
    }
}

/// Строка-переход настроек со значком в плашке, как на Android.
func settingsLink<D: View>(_ title: String, _ symbol: String, _ destination: D) -> some View {
    NavigationLink(destination: destination) {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            Text(title)
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

// MARK: - Внешний вид

struct AppearanceSettingsScreen: View {
    var body: some View {
        List {
            Section(header: Text(L("theme"))) {
                HStack {
                    Text(L("theme"))
                    Spacer()
                    Text(L("ios_theme_dark")).foregroundColor(.secondary)
                }
                Text(L("ios_themes_later")).font(.caption).foregroundColor(.secondary)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("appearance"))
    }
}

// MARK: - Плеер и аудио

struct PlayerSettingsScreen: View {
    @ObservedObject var settings: TypedStore

    var body: some View {
        List {
            Section(header: Text(L("ios_player"))) {
                NavigationLink(destination: MusicSourcesScreen()) { Text(L("music_sources")) }
                Stepper(value: Binding(get: { Int(settings.get(PK.historyDuration) ?? 30) },
                                       set: { settings.set(PK.historyDuration, Float($0)) }), in: 5...240, step: 5) {
                    HStack {
                        Text(L("history_duration"))
                        Spacer()
                        Text("\(Int(settings.get(PK.historyDuration) ?? 30)) s").foregroundColor(.secondary)
                    }
                }
            }
            Section(header: Text(L("sleep_timer"))) {
                PrefToggle(title: L("fade"), key: PK.sleepTimerFadeOut, defaultValue: false, settings: settings)
                PrefToggle(title: L("end_of_song"), key: PK.sleepTimerStopAfterCurrentSong, defaultValue: false, settings: settings)
            }
            Section(header: Text(L("queue"))) {
                PrefToggle(title: L("persistent_queue"), subtitle: L("persistent_queue_desc"), key: PK.persistentQueue, defaultValue: true, settings: settings)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("player_and_audio"))
    }
}

// MARK: - Контент (аккаунты)

struct ContentSettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore
    @State private var showSpotifyLogin = false
    @State private var confirmLogout = false

    private var spotifyLinked: Bool { !(settings.get(PK.spotifySpDc) ?? "").isEmpty }

    var body: some View {
        List {
            Section(header: Text(L("ios_accounts"))) {
                if spotifyLinked {
                    HStack {
                        Label("Spotify", systemImage: "music.note")
                        Spacer()
                        Text(settings.get(PK.spotifyUsername) ?? "").foregroundColor(.secondary).lineLimit(1)
                    }
                    PrefToggle(title: L("spotify_sync_likes"), key: PK.spotifySyncLikes, defaultValue: true, settings: settings)
                    Button(L("action_logout")) { confirmLogout = true }
                        .foregroundColor(.red)
                } else {
                    Button(action: { showSpotifyLogin = true }) {
                        Label(L("spotify_login"), systemImage: "music.note")
                    }
                }
                if (settings.get(PK.vkAccessToken) ?? "").isEmpty {
                    NavigationLink(destination: VkLoginScreen()) {
                        Label(L("vk_login"), systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    HStack {
                        Label(L("vk_music"), systemImage: "music.note.house")
                        Spacer()
                        Text(L("vk_connected")).foregroundColor(.secondary).lineLimit(1)
                    }
                    Button(L("ios_vk_logout")) {
                        settings.set(PK.vkAccessToken, nil)
                        settings.set(PK.vkUserId, nil)
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("content"))
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

// MARK: - Хранилище

struct StorageSettingsScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var confirmClear = false

    var body: some View {
        List {
            Section(header: Text(L("storage"))) {
                HStack {
                    Text(L("downloaded_songs"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(downloads.totalBytes), countStyle: .file)).foregroundColor(.secondary)
                }
                Button(L("clear_all_downloads")) { confirmClear = true }
                    .foregroundColor(.red)
                    .disabled(downloads.totalBytes == 0)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("storage"))
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
