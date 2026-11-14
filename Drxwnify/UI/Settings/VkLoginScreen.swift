import SwiftUI
import WebKit

/// Вход в VK (CRITICAL §3.3): логин и пароль → код → капча; вставка токена; вход через страницу VK.
/// После сохранения токена проверяется доступ к музыке.
struct VkLoginScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentation

    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var captchaKey = ""
    @State private var pastedToken = ""
    @State private var needCode: (viaApp: Bool, phoneMask: String?, sid: String?)?
    @State private var captcha: VkDirectAuth.Captcha?
    @State private var working = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showPage = false
    @State private var showCaptchaPage = false

    var body: some View {
        Form {
            Section(footer: Text(L("vk_password_note"))) {
                TextField(L("vk_login_phone_or_email"), text: $username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textContentType(.username)
                SecureField(L("password"), text: $password)
                    .textContentType(.password)
                if let nc = needCode {
                    TextField(L("vk_code"), text: $code).keyboardType(.numberPad)
                    Text(nc.viaApp ? L("vk_code_hint_app") : L("vk_code_hint_sms", nc.phoneMask ?? ""))
                        .font(.footnote).foregroundColor(.secondary)
                    if let sid = nc.sid {
                        Button(L(nc.viaApp ? "vk_sms_instead" : "vk_sms_resend")) { requestSms(sid) }
                    }
                }
                if let c = captcha, c.redirectUri == nil {
                    ArtworkView(url: c.imageUrl, size: 130, cornerRadius: 4, placeholderSymbol: "photo")
                    TextField(L("vk_captcha_hint"), text: $captchaKey).autocapitalization(.none).disableAutocorrection(true)
                }
                if captcha?.redirectUri != nil {
                    Text(L("vk_captcha_web_hint")).font(.footnote).foregroundColor(.secondary)
                    Button(L("vk_captcha_open")) { showCaptchaPage = true }
                }
                Button(action: { submit() }) {
                    HStack {
                        Text(L("action_login")).fontWeight(.semibold)
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(working || username.isEmpty || password.isEmpty)
            }
            if let m = message {
                Section {
                    Text(m).font(.footnote).foregroundColor(messageIsError ? .red : .green)
                }
            }
            Section(footer: Text(L("vk_paste_token_hint"))) {
                TextField("access_token", text: $pastedToken).autocapitalization(.none).disableAutocorrection(true)
                Button(L("ios_vk_save_token")) {
                    if let p = VkDirectAuth.tokenParams(pastedToken) {
                        save(token: p.token, userId: p.userId)
                    } else {
                        show(L("ios_vk_bad_token"), error: true)
                    }
                }
                .disabled(pastedToken.isEmpty || working)
            }
            Section(footer: Text(L("vk_privacy_note"))) {
                Button(L("vk_login_via_page")) { showPage = true }
            }
        }
        .navigationTitle(L("vk_login"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPage) {
            VkWebSheet(title: L("vk_login"), url: VkProvider.oauthURL, watch: "access_token") { url in
                showPage = false
                if let p = VkDirectAuth.tokenParams(url) { save(token: p.token, userId: p.userId) }
            }
        }
        .sheet(isPresented: $showCaptchaPage) {
            VkWebSheet(title: L("vk_captcha_title"), url: captcha?.redirectUri ?? "", watch: "success_token") { url in
                showCaptchaPage = false
                if let r = url.range(of: "success_token=") {
                    let token = String(url[r.upperBound...].prefix { $0 != "&" && $0 != "#" })
                    submit(captchaToken: token.removingPercentEncoding ?? token)
                }
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func requestSms(_ sid: String) {
        Task {
            let failure = await VkDirectAuth.requestSms(validationSid: sid)
            await MainActor.run {
                if let f = failure { show(L("vk_sms_failed", f), error: true) } else { show(L("vk_sms_sent"), error: false) }
            }
        }
    }

    private func submit(captchaToken: String? = nil) {
        working = true
        message = nil
        let u = username, p = password, c = code, key = captchaKey, answered = captcha
        Task {
            let result = await VkDirectAuth.login(username: u, password: p, code: c.isEmpty ? nil : c,
                                                  captchaKey: key.isEmpty ? nil : key,
                                                  captchaSuccessToken: captchaToken, captcha: answered)
            await MainActor.run {
                working = false
                switch result {
                case .success(let token, let userId):
                    save(token: token, userId: userId)
                case .needCode(let viaApp, let mask, let sid):
                    captcha = nil
                    needCode = (viaApp, mask, sid)
                    if !viaApp, let sid = sid { requestSms(sid) }
                case .needCaptcha(let cap):
                    captchaKey = ""
                    captcha = cap
                    if captchaToken != nil { show(L("vk_captcha_again"), error: true) }
                    if cap.redirectUri != nil { showCaptchaPage = true }
                case .error(let text):
                    show(text, error: true)
                }
            }
        }
    }

    /// Сохраняет токен и сразу спрашивает у VK, открыт ли этому входу музыкальный API.
    private func save(token: String, userId: String?) {
        let s = env.prefs.settings
        let wasLinked = MainAccount.shared.isLinked(.VK)
        let mainBefore = MainAccount.shared.main
        s.set(PK.vkAccessToken, token)
        MainAccount.shared.didLink(.VK, wasLinked: wasLinked, mainBefore: mainBefore)
        env.spotify.vkCatalog?.invalidate()
        if let id = userId { s.set(PK.vkUserId, id) }
        working = true
        let vk = env.vk
        Task {
            let access = await vk.checkAudioAccess()
            await MainActor.run {
                working = false
                switch access {
                case .ok:
                    show(L("vk_connected") + ". " + L("vk_check_audio_ok"), error: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { presentation.wrappedValue.dismiss() }
                case .failed(let code, let text):
                    show(L("vk_check_audio_failed", code.map(String.init) ?? "?", text) + "\n" + L("vk_check_audio_relogin"), error: true)
                case .noToken:
                    show(L("not_logged_in"), error: true)
                }
            }
        }
    }
}

/// Страница VK в листе: закрывается, когда в адресе появляется нужный параметр.
private struct VkWebSheet: View {
    let title: String
    let url: String
    let watch: String
    let onFound: (String) -> Void
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            VkWebView(url: url, watch: watch, onFound: onFound)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(leading: Button(L("cancel")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct VkWebView: UIViewRepresentable {
    let url: String
    let watch: String
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(watch: watch, onFound: onFound) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        if let u = URL(string: url) { view.load(URLRequest(url: u)) }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let watch: String
        private let onFound: (String) -> Void
        private var done = false

        init(watch: String, onFound: @escaping (String) -> Void) {
            self.watch = watch
            self.onFound = onFound
        }

        private func check(_ url: URL?) -> Bool {
            guard !done, let s = url?.absoluteString, s.contains(watch + "=") else { return false }
            done = true
            DispatchQueue.main.async { self.onFound(s) }
            return true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(check(navigationAction.request.url) ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = check(webView.url)
        }
    }
}
