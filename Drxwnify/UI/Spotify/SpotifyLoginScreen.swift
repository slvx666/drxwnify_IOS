import SwiftUI
import WebKit

/// Вход в Spotify через WebView (INT-002): после перехода на `open.spotify.com`
/// из хранилища cookie берутся `sp_dc` (обязательна) и `sp_key`.
struct SpotifyLoginScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentationMode

    @State private var status: String?
    @State private var failed = false
    @State private var working = false
    @State private var attempt = 0

    var body: some View {
        NavigationView {
            ZStack {
                SpotifyLoginWebView(onCookies: handleCookies)
                    .id(attempt)
                    .opacity(working ? 0 : 1)
                if working || failed {
                    VStack(spacing: 16) {
                        if working { ProgressView() }
                        if let status = status {
                            Text(status).multilineTextAlignment(.center)
                        }
                        if failed {
                            Button(L("retry")) {
                                failed = false
                                status = nil
                                attempt += 1
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
                }
            }
            .navigationTitle(L("spotify_login"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("cancel")) { presentationMode.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func handleCookies(spDc: String, spKey: String) {
        guard !working else { return }
        working = true
        failed = false
        status = L("spotify_status_verifying")
        let env = self.env
        Task {
            do {
                try await SpotifyLogin.complete(spDc: spDc, spKey: spKey, env: env) { step in
                    DispatchQueue.main.async {
                        switch step {
                        case .connecting: status = L("spotify_status_connecting")
                        case .loadingProfile: status = L("spotify_status_loading_profile")
                        case .done: status = L("spotify_login_success")
                        }
                    }
                }
                try? await sleepSeconds(0.3)
                await MainActor.run { presentationMode.wrappedValue.dismiss() }
            } catch {
                await MainActor.run {
                    working = false
                    failed = true
                    status = SpotifyLogin.message(for: error)
                }
            }
        }
    }
}

private struct SpotifyLoginWebView: UIViewRepresentable {
    let onCookies: (_ spDc: String, _ spKey: String) -> Void

    /// Мобильный Safari: со стандартным UA WKWebView часть страниц входа считает браузер неподдерживаемым.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Чистое хранилище на каждый вход — как `removeAllCookies` на Android.
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: SpotifyAuth.loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCookies: (String, String) -> Void
        private var finished = false

        init(onCookies: @escaping (String, String) -> Void) { self.onCookies = onCookies }

        private func isPlayer(_ url: URL?) -> Bool {
            url?.absoluteString.hasPrefix("https://open.spotify.com") == true
        }

        /// Читает cookie; если `sp_dc` уже есть — останавливает страницу и отдаёт их.
        private func tryExtract(_ webView: WKWebView) {
            guard !finished else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.finished else { return }
                let spotify = cookies.filter { $0.domain.hasSuffix("spotify.com") }
                guard let spDc = spotify.first(where: { $0.name == "sp_dc" && !$0.value.isEmpty })?.value else { return }
                let spKey = spotify.first(where: { $0.name == "sp_key" })?.value ?? ""
                self.finished = true
                webView.stopLoading()
                self.onCookies(spDc, spKey)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Cookie может быть готова уже на редиректе; если нет — подхватим после загрузки страницы.
            if isPlayer(navigationAction.request.url) { tryExtract(webView) }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if isPlayer(webView.url) { tryExtract(webView) }
        }

        /// Вход через Google/Facebook/Apple открывает новое окно: грузим его в этом же WebView.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
