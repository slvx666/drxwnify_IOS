import Foundation
import CryptoKit
import Combine

/// Last.fm (INT-016) — перенос `lastfm/.../LastFM.kt`: вход логином и паролем (auth.getMobileSession),
/// «сейчас играет», скробблинг засчитанных прослушиваний, лайки → love.
/// Ключ и секрет — из `secrets.xcconfig` (вне git) через Info.plist.
final class LastFM: ObservableObject {
    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let apiKey = (Bundle.main.object(forInfoDictionaryKey: "LastFMApiKey") as? String) ?? ""
    static let secret = (Bundle.main.object(forInfoDictionaryKey: "LastFMSecret") as? String) ?? ""
    static var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty && !apiKey.hasPrefix("$(") }

    private let settings: TypedStore
    private var cancellables = Set<AnyCancellable>()
    private var nowPlayingId: String?
    private var trackStarted = Date()

    init(settings: TypedStore) {
        self.settings = settings
    }

    var session: String? {
        let s = settings.get(PK.lastfmSession) ?? ""
        return s.isEmpty ? nil : s
    }

    var isLoggedIn: Bool { session != nil && Self.isConfigured }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Запрос с подписью

    private func call(_ method: String, _ extra: [String: String], signedWithSession: Bool = true) async throws -> JSONObject {
        var params = ["method": method, "api_key": Self.apiKey]
        if signedWithSession, let sk = session { params["sk"] = sk }
        for (k, v) in extra { params[k] = v }
        let toHash = params.keys.sorted().map { $0 + params[$0]! }.joined() + Self.secret
        let sig = Insecure.MD5.hash(data: Data(toHash.utf8)).map { String(format: "%02x", $0) }.joined()
        var form = params
        form["api_sig"] = sig
        form["format"] = "json"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var r = URLRequest(url: Self.endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("Drxwnify iOS (https://drxwnify.pages.dev)", forHTTPHeaderField: "User-Agent")
        r.httpBody = form.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let resp = try await HTTP.send(r)
        guard let o = JSON.object(resp.data) else { throw Failure(message: "Last.fm HTTP \(resp.status)") }
        if o["error"] != nil { throw Failure(message: o.str("message") ?? "Last.fm error \(o.str("error") ?? "")") }
        return o
    }

    // MARK: - Вход

    func login(username: String, password: String) async throws {
        let o = try await call("auth.getMobileSession", ["username": username, "password": password], signedWithSession: false)
        guard let s = o.obj("session"), let key = s.str("key") else { throw Failure(message: "Last.fm: no session") }
        await MainActor.run {
            settings.set(PK.lastfmSession, key)
            settings.set(PK.lastfmUsername, s.str("name") ?? username)
            objectWillChange.send()
        }
    }

    func logout() {
        settings.set(PK.lastfmSession, nil)
        settings.set(PK.lastfmUsername, nil)
        objectWillChange.send()
    }

    // MARK: - Плеер

    /// Подписка на плеер: смена трека → «сейчас играет», засчитанное прослушивание → скроббл.
    func attach(_ player: PlayerController) {
        player.$currentIndex
            .receive(on: DispatchQueue.main)
            .map { [weak player] _ in player?.current }
            .removeDuplicates { (a: Track?, b: Track?) in a?.id == b?.id }
            .sink { [weak self] (t: Track?) in
                guard let self = self, let t = t else { return }
                self.trackStarted = Date()
                self.nowPlayingId = t.id
                guard self.isLoggedIn, self.settings.get(PK.lastfmUseNowPlaying) ?? true else { return }
                Task { _ = try? await self.call("track.updateNowPlaying", self.fields(t)) }
            }
            .store(in: &cancellables)
    }

    /// Вызывается, когда прослушивание засчитано (половина трека, 30 с – 4 мин).
    func scrobble(_ t: Track) {
        guard isLoggedIn, settings.get(PK.lastfmScrobblingEnable) ?? true else { return }
        let started = nowPlayingId == t.id ? trackStarted : Date().addingTimeInterval(-Double(t.durationMs) / 2000)
        var f = [String: String]()
        for (k, v) in fields(t) { f[k + "[0]"] = v }
        f["timestamp[0]"] = String(Int(started.timeIntervalSince1970))
        Task { _ = try? await call("track.scrobble", f) }
    }

    /// Лайк в приложении → love/unlove (настройка «Отправлять лайки»).
    func love(_ t: Track, _ on: Bool) {
        guard isLoggedIn, settings.get(PK.lastfmUseSendLikes) ?? false else { return }
        let f = fields(t)
        Task { _ = try? await call(on ? "track.love" : "track.unlove", ["artist": f["artist"] ?? "", "track": f["track"] ?? ""]) }
    }

    private func fields(_ t: Track) -> [String: String] {
        var f = ["artist": t.artists.first?.name ?? t.artistNames, "track": t.title]
        if let a = t.albumName, !a.isEmpty { f["album"] = a }
        if t.durationMs > 0 { f["duration"] = String(t.durationMs / 1000) }
        return f
    }
}
