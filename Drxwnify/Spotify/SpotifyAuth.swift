import Foundation
import CryptoKit

/// Токен веб-плеера Spotify по cookie `sp_dc` (INT-002, INT-004; `spec/CRITICAL.md` §3.1).
/// Порт `android/spotify/.../SpotifyAuth.kt`.
enum SpotifyAuth {
    static let loginURL = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!

    private static let tokenURL = "https://open.spotify.com/api/token"
    private static let serverTimeURL = "https://open.spotify.com/api/server-time"
    /// Секрет TOTP и его версия: Spotify их меняет, актуальные лежат в общедоступном gist.
    private static let nuanceGistURL = "https://api.github.com/gists/22ed9c6ba463899e933427f7de1f0eef"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// Токен для тех, кто не вошёл: хватает на публичный каталог, но не на медиатеку.
    static func fetchAnonymousToken() async throws -> SpotifyInternalToken {
        let token = try await fetchToken(reason: "init", cookie: nil)
        if token.accessToken.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SpotifyError(statusCode: 401, message: "Spotify refused an anonymous token")
        }
        return token
    }

    static func fetchAccessToken(spDc: String, spKey: String = "") async throws -> SpotifyInternalToken {
        var cookie = "sp_dc=\(spDc)"
        if !spKey.isEmpty { cookie += "; sp_key=\(spKey)" }
        let token = try await fetchToken(reason: "transport", cookie: cookie)
        if token.isAnonymous || token.accessToken.trimmingCharacters(in: .whitespaces).isEmpty {
            // Слова «anonymous» и «expired» в тексте важны: по ним сессия считается истёкшей.
            throw SpotifyError(statusCode: 401, message: "Received anonymous token — sp_dc cookie is invalid or expired")
        }
        return token
    }

    private static func fetchToken(reason: String, cookie: String?) async throws -> SpotifyInternalToken {
        let nuance = try await fetchNuance()
        let serverTime = try await fetchServerTime()
        let totp = generateTotp(secret: nuance.secret, serverTimeSec: serverTime)
        let url = "\(tokenURL)?reason=\(reason)&productType=web-player&totp=\(totp)&totpServer=\(totp)&totpVer=\(nuance.version)"
        let body = try await httpGet(url, extraHeaders: cookie.map { ["Cookie": $0] } ?? [:])
        guard let json = JSON.object(body), let accessToken = json.str("accessToken") else {
            throw SpotifyError(statusCode: 500, message: "Invalid token response")
        }
        return SpotifyInternalToken(
            accessToken: accessToken,
            accessTokenExpirationTimestampMs: Int64(json.double("accessTokenExpirationTimestampMs") ?? 0),
            isAnonymous: json.bool("isAnonymous") ?? false
        )
    }

    private static func fetchNuance() async throws -> (secret: String, version: Int) {
        let body: Data
        do {
            body = try await httpGet(nuanceGistURL, extraHeaders: [:])
        } catch {
            throw SpotifyError(statusCode: 503, message: "Failed to fetch TOTP secret from gist: \(error.localizedDescription)")
        }
        guard let files = JSON.object(body)?.obj("files"),
              let content = files.values.compactMap({ ($0 as? JSONObject)?.str("content") }).first else {
            throw SpotifyError(statusCode: 500, message: "Gist has no files")
        }
        let nuances = (JSON.array(Data(content.utf8)) ?? []).compactMap { item -> (String, Int)? in
            guard let o = item as? JSONObject, let s = o.str("s"), let v = o.int("v") else { return nil }
            return (s, v)
        }
        guard let best = nuances.max(by: { $0.1 < $1.1 }) else {
            throw SpotifyError(statusCode: 500, message: "No nuance data found in gist")
        }
        return best
    }

    private static func fetchServerTime() async throws -> Int64 {
        let body: Data
        do {
            body = try await httpGet(serverTimeURL, extraHeaders: [:])
        } catch {
            throw SpotifyError(statusCode: 503, message: "Failed to fetch Spotify server time: \(error.localizedDescription)")
        }
        guard let time = JSON.object(body)?.double("serverTime") else {
            throw SpotifyError(statusCode: 500, message: "Invalid server time response")
        }
        return Int64(time)
    }

    /// TOTP по RFC 6238: 6 цифр, HMAC-SHA1, шаг 30 с, секрет в base32.
    static func generateTotp(secret: String, serverTimeSec: Int64) -> String {
        let key = base32Decode(secret)
        var step = UInt64(bitPattern: serverTimeSec / 30)
        if serverTimeSec < 0 { step = UInt64(bitPattern: Int64((Double(serverTimeSec) / 30).rounded(.down))) }
        var timeBytes = [UInt8](repeating: 0, count: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            timeBytes[i] = UInt8(step & 0xFF)
            step >>= 8
        }
        let hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: timeBytes, using: SymmetricKey(data: key)))
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let code = (UInt32(hash[offset] & 0x7F) << 24) | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        let otp = String(code % 1_000_000)
        return String(repeating: "0", count: max(0, 6 - otp.count)) + otp
    }

    static func base32Decode(_ input: String) -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bitsLeft = 0
        for c in input.uppercased() where c != "=" {
            guard let value = alphabet.firstIndex(of: c) else { continue }
            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xFF))
            }
        }
        return output
    }

    private static func httpGet(_ urlString: String, extraHeaders: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SpotifyError(statusCode: 400, message: "Bad URL") }
        var headers = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en",
        ]
        extraHeaders.forEach { headers[$0.key] = $0.value }
        let response = try await HTTP.get(url, headers: headers, timeout: 15)
        guard response.isSuccess else {
            throw SpotifyError(statusCode: response.status, message: "HTTP \(response.status): \(response.text)")
        }
        return response.data
    }
}
