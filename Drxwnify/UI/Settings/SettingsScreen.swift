import SwiftUI

/// Корень настроек. Полный набор экранов — этап 13.
struct SettingsScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        SettingsContent(settings: env.prefs.settings)
    }
}

private struct SettingsContent: View {
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
                    Button(L("action_logout")) { confirmLogout = true }
                        .foregroundColor(.red)
                } else {
                    Button(action: { showSpotifyLogin = true }) {
                        Label(L("spotify_login"), systemImage: "music.note")
                    }
                }
            }
            Section {
                NavigationLink(destination: BackupScreen()) {
                    Label(L("backup_restore"), systemImage: "externaldrive")
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("settings"))
        .miniPlayerInset()
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
