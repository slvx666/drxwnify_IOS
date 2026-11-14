import Foundation

/// Завершение входа в Spotify после получения cookie из WebView (INT-002).
/// Порт `ui/screens/SpotifyLoginScreen.kt:691-840`.
enum SpotifyLogin {
    enum Step { case connecting, loadingProfile, done }

    static func complete(spDc: String, spKey: String, env: AppEnvironment, onStep: @escaping (Step) -> Void) async throws {
        let settings = env.prefs.settings
        onStep(.connecting)
        let token = try await SpotifyAuth.fetchAccessToken(spDc: spDc, spKey: spKey)
        let wasLinked = MainAccount.shared.isLinked(.SPOTIFY)
        let mainBefore = MainAccount.shared.main
        await env.spotifyTokens.saveSession(spDc: spDc, spKey: spKey, token: token)

        onStep(.loadingProfile)
        // Профиль не обязателен: без него вход всё равно считается выполненным.
        if let user = try? await env.spotify.me() {
            settings.set(PK.spotifyUsername, user.displayName ?? user.id)
            settings.set(PK.spotifyUserId, user.id)
        }

        // Подключённый аккаунт сразу становится источником каталога и медиатеки.
        settings.set(PK.enableSpotify, true)
        settings.set(PK.useSpotifySearch, true)
        settings.set(PK.useSpotifyHome, true)
        // Остальное включается только при первом подключении: повторный вход не трогает выбор пользователя.
        if settings.get(PK.spotifyHomeOnly) == nil { settings.set(PK.spotifyHomeOnly, true) }
        if settings.get(PK.spotifySyncLikes) == nil { settings.set(PK.spotifySyncLikes, true) }
        // Первое подключение Spotify делает его основным; перелогин основной не меняет (Android 2.3.0).
        await MainActor.run { MainAccount.shared.didLink(.SPOTIFY, wasLinked: wasLinked, mainBefore: mainBefore) }
        onStep(.done)
    }

    /// Понятный текст ошибки входа.
    static func message(for error: Error) -> String {
        if let e = error as? SpotifyError {
            if e.message.contains("anonymous") || e.message.contains("expired") { return L("spotify_login_error_expired") }
            if e.statusCode == 503 || e.statusCode == 0 { return L("spotify_login_error_network") }
            if e.statusCode == 429 || e.statusCode == 403 || e.statusCode == 400 { return L("spotify_login_error_rejected") }
            return L("spotify_login_error")
        }
        if error is URLError { return L("spotify_login_error_network") }
        return L("spotify_login_error")
    }
}
