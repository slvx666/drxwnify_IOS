import Foundation

/// Прямой вход в VK по логину и паролю (CRITICAL §3.3) — перенос `resolver/providers/VkDirectAuth.kt`.
/// Логин и пароль уходят только в VK и нигде не сохраняются; на устройстве остаётся токен.
enum VkDirectAuth {
    struct Captcha {
        var sid: String
        var imageUrl: String
        /// Новая проверка «я не робот»: страница, которую проходят в браузере.
        var redirectUri: String?
        var ts: String?
        var attempt: String?
    }

    enum Result {
        case success(token: String, userId: String?)
        /// VK ждёт код. SMS сам не уходит: только после `requestSms` с `validationSid`.
        case needCode(viaApp: Bool, phoneMask: String?, validationSid: String?)
        case needCaptcha(Captcha)
        case error(String)
    }

    // Официальный Android-клиент VK (тот же, что `VkProvider.oauthClientId`): публичная константа приложения из кода Android.
    private static let clientSecret = "hHbZxrka2uZ6jB1inYsH"

    /// Один идентификатор на установку, как у настоящего устройства: VK привязывает к нему сессию.
    private static let deviceId: String = {
        let key = "vkDeviceId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = (0..<16).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static func post(_ url: String, _ fields: [(String, String)]) async throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(VkProvider.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await HTTP.send(request).text
    }

    /// Просит VK прислать код по SMS. nil — принято, иначе ответ VK.
    static func requestSms(validationSid: String) async -> String? {
        do {
            let text = try await post("https://api.vk.com/method/auth.validatePhone", [
                ("sid", validationSid), ("api_id", VkProvider.oauthClientId), ("client_id", VkProvider.oauthClientId),
                ("client_secret", clientSecret), ("v", VkProvider.apiVersion), ("lang", "ru"), ("device_id", deviceId),
            ])
            guard let json = JSON.object(text) else { return "Unexpected response from VK" }
            let message = json.obj("error")?.str("error_msg")
            return (message?.isEmpty ?? true) ? nil : message
        } catch {
            return error.localizedDescription
        }
    }

    static func login(username: String, password: String, code: String? = nil, captchaKey: String? = nil,
                      captchaSuccessToken: String? = nil, captcha: Captcha? = nil) async -> Result {
        var fields: [(String, String)] = [
            ("grant_type", "password"), ("client_id", VkProvider.oauthClientId), ("client_secret", clientSecret),
            ("username", username.trimmingCharacters(in: .whitespaces)), ("password", password), ("scope", "all"),
            ("2fa_supported", "1"), ("v", VkProvider.apiVersion), ("lang", "ru"), ("device_id", deviceId),
        ]
        if let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty { fields.append(("code", code)) }
        if let c = captcha, !c.sid.isEmpty, let key = captchaKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            fields.append(("captcha_sid", c.sid))
            fields.append(("captcha_key", key))
        }
        if let token = captchaSuccessToken, !token.isEmpty {
            fields.append(("success_token", token))
            if let c = captcha {
                if !c.sid.isEmpty { fields.append(("captcha_sid", c.sid)) }
                if let ts = c.ts { fields.append(("captcha_ts", ts)) }
                if let a = c.attempt { fields.append(("captcha_attempt", a)) }
            }
        }
        do {
            return parse(try await post("https://oauth.vk.com/token", fields))
        } catch {
            return .error(L("vk_load_failed") + ": " + error.localizedDescription)
        }
    }

    static func parse(_ text: String) -> Result {
        guard let json = JSON.object(text) else { return .error("Unexpected response from VK") }
        if let token = json.str("access_token"), !token.isEmpty {
            return .success(token: token, userId: json.str("user_id"))
        }
        switch json.str("error") ?? "" {
        case "need_validation":
            return .needCode(viaApp: json.str("validation_type") == "2fa_app",
                             phoneMask: json.str("phone_mask").flatMap { $0.isEmpty ? nil : $0 },
                             validationSid: json.str("validation_sid").flatMap { $0.isEmpty ? nil : $0 })
        case "need_captcha":
            return .needCaptcha(Captcha(sid: json.str("captcha_sid") ?? "", imageUrl: json.str("captcha_img") ?? "",
                                        redirectUri: json.str("redirect_uri").flatMap { $0.hasPrefix("https://") ? $0 : nil },
                                        ts: json.str("captcha_ts"), attempt: json.str("captcha_attempt")))
        default:
            let d = json.str("error_description") ?? ""
            let e = json.str("error") ?? ""
            return .error(!d.isEmpty ? d : (!e.isEmpty ? e : "VK login failed"))
        }
    }

    /// Токен и id пользователя из redirect-адреса OAuth или вставленного текста (принимается и целый URL, и голый токен).
    static func tokenParams(_ text: String) -> (token: String, userId: String?)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func param(_ name: String) -> String? {
            guard let r = s.range(of: name + "=") else { return nil }
            let tail = s[r.upperBound...]
            let value = tail.prefix { $0 != "&" && $0 != "#" && $0 != " " }
            return value.isEmpty ? nil : String(value)
        }
        if let t = param("access_token") { return (t, param("user_id")) }
        if !s.isEmpty, !s.contains("/"), !s.contains(" "), !s.contains("="), s.count > 20 { return (s, nil) }
        return nil
    }
}
