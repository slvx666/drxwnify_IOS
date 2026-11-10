import Foundation
import Combine

/// Выдаёт токен для каждого запроса к Spotify (INT-003, INT-004; `spec/CRITICAL.md` §3.1, п. 5).
/// Аккаунт привязан — токен аккаунта с обновлением по `sp_dc`; нет — анонимный.
/// Порт `utils/SpotifyTokenManager.kt`.
actor SpotifyTokenManager {
    /// Состояние для интерфейса.
    final class State: ObservableObject {
        /// Cookie истекла: нужно войти заново.
        @Published var needsReLogin = false
    }

    nonisolated let state = State()

    private let settings: TypedStore
    private static let forcedRefreshGapMs: Int64 = 10_000

    private var lastRefreshAtMs: Int64 = 0
    private var anonymousToken: (token: String, expiresAtMs: Int64)?
    private var refreshTask: Task<Bool, Never>?
    private var anonymousTask: Task<Bool, Never>?

    init(settings: TypedStore) {
        self.settings = settings
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    nonisolated var isLinked: Bool {
        !(settings.get(PK.spotifySpDc) ?? "").isEmpty
    }

    /// Токен для запроса. `forceRefresh`: сервер ответил 401 раньше заявленного срока.
    func token(forceRefresh: Bool = false) async -> String? {
        if !isLinked {
            if forceRefresh { anonymousToken = nil }
            return await ensurePublicAccess() ? anonymousToken?.token : nil
        }
        // Пачка одновременных 401 обновляет токен только один раз.
        if forceRefresh && Self.nowMs - lastRefreshAtMs > Self.forcedRefreshGapMs {
            settings.set(PK.spotifyTokenExpiry, 0)
        }
        return await ensureAuthenticated() ? settings.get(PK.spotifyAccessToken) : nil
    }

    /// Анонимный токен: поиск и публичные альбомы, артисты, плейлисты без входа.
    func ensurePublicAccess() async -> Bool {
        if let t = anonymousToken, Self.nowMs < t.expiresAtMs { return true }
        if let running = anonymousTask { return await running.value }
        let task = Task { () -> Bool in
            guard let token = try? await SpotifyAuth.fetchAnonymousToken() else { return false }
            self.setAnonymous(token)
            return true
        }
        anonymousTask = task
        let ok = await task.value
        anonymousTask = nil
        return ok
    }

    private func setAnonymous(_ token: SpotifyInternalToken) {
        anonymousToken = (token.accessToken, token.accessTokenExpirationTimestampMs)
    }

    /// Проверяет токен аккаунта и при истечении обновляет его по cookie.
    /// Одновременно во всём приложении идёт только одно обновление.
    func ensureAuthenticated() async -> Bool {
        let accessToken = settings.get(PK.spotifyAccessToken) ?? ""
        let expiry = Int64(settings.get(PK.spotifyTokenExpiry) ?? 0)
        if accessToken.isEmpty { return false }
        if Self.nowMs < expiry { return true }

        if let running = refreshTask { return await running.value }
        let task = Task { () -> Bool in await self.refresh() }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func refresh() async -> Bool {
        // Перечитываем: другой вызывающий мог уже обновить.
        let freshToken = settings.get(PK.spotifyAccessToken) ?? ""
        let freshExpiry = Int64(settings.get(PK.spotifyTokenExpiry) ?? 0)
        if !freshToken.isEmpty && Self.nowMs < freshExpiry { return true }

        let spDc = settings.get(PK.spotifySpDc) ?? ""
        let spKey = settings.get(PK.spotifySpKey) ?? ""
        if spDc.isEmpty { return false }

        do {
            let token = try await SpotifyAuth.fetchAccessToken(spDc: spDc, spKey: spKey)
            settings.set(PK.spotifyAccessToken, token.accessToken)
            settings.set(PK.spotifyTokenExpiry, Int(token.accessTokenExpirationTimestampMs))
            lastRefreshAtMs = Self.nowMs
            setNeedsReLogin(false)
            return true
        } catch {
            let message = (error as? SpotifyError)?.message ?? error.localizedDescription
            if message.contains("anonymous") || message.contains("expired") {
                clearSession()
                setNeedsReLogin(true)
            }
            return false
        }
    }

    /// Сохраняет сессию после входа через WebView.
    func saveSession(spDc: String, spKey: String, token: SpotifyInternalToken) {
        settings.set(PK.spotifySpDc, spDc)
        settings.set(PK.spotifySpKey, spKey)
        settings.set(PK.spotifyAccessToken, token.accessToken)
        settings.set(PK.spotifyTokenExpiry, Int(token.accessTokenExpirationTimestampMs))
        lastRefreshAtMs = Self.nowMs
        setNeedsReLogin(false)
    }

    func clearSession() {
        settings.set(PK.spotifyAccessToken, nil)
        settings.set(PK.spotifySpDc, nil)
        settings.set(PK.spotifySpKey, nil)
        settings.set(PK.spotifyTokenExpiry, nil)
    }

    /// Выход из аккаунта: сессия и имя пользователя.
    func logout() {
        clearSession()
        settings.set(PK.spotifyUsername, nil)
        settings.set(PK.spotifyUserId, nil)
        setNeedsReLogin(false)
    }

    private nonisolated func setNeedsReLogin(_ value: Bool) {
        DispatchQueue.main.async { self.state.needsReLogin = value }
    }
}
