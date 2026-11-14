import SwiftUI
import WebKit

/// Вход в Яндекс Музыку (INT-010, CRITICAL §3.2): страница OAuth implicit grant в WebView,
/// токен — из фрагмента `access_token` адреса возврата; затем `account/status` → uid и имя.
/// Через VPN Яндекс часто не открывает вход — подсказка `yandex_vpn_hint` всегда видна.
struct YandexLoginScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentationMode

    @State private var working = false
    @State private var error: String?
    @State private var attempt = 0
    @State private var manualToken = ""
    @State private var showManual = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Text(L("yandex_vpn_hint")).font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    YandexOAuthWebView(onToken: complete).id(attempt).opacity(working ? 0 : 1)
                    if working || error != nil {
                        VStack(spacing: 16) {
                            if working { ProgressView() }
                            if let e = error {
                                Text(e).multilineTextAlignment(.center)
                                Button(L("retry")) { error = nil; attempt += 1 }
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemBackground))
                    }
                }
                if showManual {
                    HStack {
                        TextField("OAuth token", text: $manualToken).autocapitalization(.none).disableAutocorrection(true)
                        Button(L("ios_paste")) { manualToken = UIPasteboard.general.string ?? "" }
                        Button("OK") { complete(manualToken.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(manualToken.isEmpty)
                    }
                    .padding(12)
                }
            }
            .navigationTitle(L("yandex_login"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("cancel")) { presentationMode.wrappedValue.dismiss() },
                                trailing: Button(action: { showManual.toggle() }) { Image(systemName: "key") })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func complete(_ token: String) {
        guard !working, !token.isEmpty else { return }
        working = true
        error = nil
        let settings = env.prefs.settings
        let api = env.spotify
        let previous = settings.get(PK.yandexAccessToken)
        let wasLinked = MainAccount.shared.isLinked(.YANDEX)
        let mainBefore = MainAccount.shared.main
        settings.set(PK.yandexAccessToken, token)
        Task {
            do {
                api.yandex?.logout()
                guard let account = try await api.yandex?.account() else { throw YandexError(status: 500, message: "Yandex") }
                await MainActor.run {
                    settings.set(PK.yandexUid, account.uid)
                    settings.set(PK.yandexUsername, account.displayName ?? account.login ?? account.uid)
                    // Основным становится, только если основного ещё не было (Android 2.3.0 `defaultMakeMain`).
                    MainAccount.shared.didLink(.YANDEX, wasLinked: wasLinked, mainBefore: mainBefore)
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                await MainActor.run {
                    settings.set(PK.yandexAccessToken, previous)
                    working = false
                    self.error = L("yandex_vpn_login_failed") + "\n\n" + error.localizedDescription
                }
            }
        }
    }
}

/// WebView страницы OAuth: ловит переход на адрес с `#access_token=…`.
struct YandexOAuthWebView: UIViewRepresentable {
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: YandexAPI.oauthURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        private var done = false

        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, check(url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { _ = check(url) }
        }

        private func check(_ url: URL) -> Bool {
            guard !done, let fragment = url.fragment, fragment.contains("access_token=") else { return false }
            let pairs = fragment.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            guard let token = pairs.first(where: { $0.first == "access_token" })?.last, !token.isEmpty else { return false }
            done = true
            DispatchQueue.main.async { self.onToken(token) }
            return true
        }
    }
}
