import SwiftUI

enum AppTab: Hashable {
    case home, search, library
}

/// Корень: 3 вкладки, как на Android (UI-001): Главная, Поиск, Библиотека; «Вместе» — значок в шапке.
/// Мини-плеер над навигацией (UI-051).
struct RootView: View {
    /// Вкладка при запуске (`defaultOpenTab`, SET-029).
    @State private var tab: AppTab = {
        switch UserDefaults(suiteName: "ds.settings")?.string(forKey: "defaultOpenTab") {
        case "EXPLORE", "SEARCH": return .search
        case "LIBRARY": return .library
        default: return .home
        }
    }()
    @State private var showPlayer = false
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var suggestions = Suggestions.shared

    /// Высота стандартной панели вкладок над безопасной зоной (iOS 14–25).
    static let classicTabBarHeight: CGFloat = 49

    var body: some View {
        content
            .onOpenURL { url in
                if env.friends.openInvite(url) { tab = .home; env.showTogether = true; return }
                if let t = AppLinks.parse(url) { env.linkTarget = t }
            }
            .alert(isPresented: Binding(get: { env.friends.invite != nil }, set: { if !$0 { env.friends.invite = nil } })) {
                let name = env.friends.invite?.name ?? ""
                return Alert(title: Text(L("ios_invite_title")),
                             message: Text(L("ios_invite_message", name.isEmpty ? String((env.friends.invite?.pubkey ?? "").prefix(8)) : name)),
                             primaryButton: .default(Text(L("ios_friends_add"))) { env.friends.answerInvite(accept: true) },
                             secondaryButton: .cancel(Text(L("cancel"))) { env.friends.answerInvite(accept: false) })
            }
            .background(EmptyView().sheet(item: $env.linkTarget) { target in
                NavigationView {
                    LinkTargetScreen(target: target)
                        .navigationBarItems(leading: Button(L("close")) { env.linkTarget = nil })
                }
                .navigationViewStyle(StackNavigationViewStyle())
                .environmentObject(env)
                .environmentObject(player)
                .environmentObject(env.likes)
                .environmentObject(env.downloads)
                .environmentObject(env.friends)
                .environmentObject(env.chats)
                .preferredColorScheme(.dark)
            })
            .background(EmptyView().sheet(item: $env.trackMenu) { req in
                TrackMenuSheet(track: req.track,
                               isCurrent: player.current?.id == req.track.id,
                               navigate: { env.linkTarget = $0 },
                               addToPlaylist: { env.addToPlaylist = TrackBatch(tracks: [req.track]) },
                               removeTitle: req.removeTitle,
                               onRemove: req.onRemove)
                    .environmentObject(env)
                    .environmentObject(player)
                    .environmentObject(env.likes)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
                    .modifier(MediumSheet())
            })
            .background(EmptyView().sheet(item: $env.trackSelection) { batch in
                TrackSelectionSheet(tracks: batch.tracks)
                    .environmentObject(env)
                    .environmentObject(player)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
            })
            .background(EmptyView().sheet(item: $env.addToPlaylist) { batch in
                AddToPlaylistSheet(batch: batch)
                    .environmentObject(env)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
            })
            .background(EmptyView().sheet(item: Binding(get: { suggestions.replies.first }, set: { _ in })) { reply in
                SuggestionReplySheet(reply: reply).preferredColorScheme(.dark)
            })
            .sheet(isPresented: $showPlayer) {
                PlayerScreen()
                    .environmentObject(env)
                    .environmentObject(player)
                    .environmentObject(env.likes)
                    .environmentObject(env.downloads)
                    .environmentObject(env.friends)
                    .environmentObject(env.chats)
                    .preferredColorScheme(.dark)
            }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            tabs
                .tabViewBottomAccessory {
                    MiniPlayerView(style: .accessory, showPlayer: $showPlayer)
                }
        } else {
            ZStack(alignment: .bottom) {
                tabs
                if !env.chatOpen {
                    MiniPlayerView(style: .classic, showPlayer: $showPlayer)
                        .padding(.bottom, env.chromeHidden ? 0 : Self.classicTabBarHeight)
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Панель вкладок прячется системой; мини-плеер едет вслед за ней, а не прыгает.
            .animation(.easeInOut(duration: 0.28), value: env.chromeHidden)
            .animation(.easeInOut(duration: 0.22), value: env.chatOpen)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            tabPage(HomeScreen())
                .tabItem { Label(L("home"), systemImage: "house.fill") }
                .tag(AppTab.home)
            tabPage(SearchScreen())
                .tabItem { Label(L("search"), systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            tabPage(LibraryScreen())
                .tabItem { Label(L("filter_library"), systemImage: "music.note.list") }
                .tag(AppTab.library)
        }
    }

    private func tabPage<Content: View>(_ content: Content) -> some View {
        NavigationView { content }
            .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// Отступ снизу под мини-плеер для прокручиваемого содержимого (на iOS 26 система делает это сама).
struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.padding(.bottom, MiniPlayerView.classicHeight + 8)
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
    /// Прячет панель вкладок, пока экран открыт («Вместе», чат).
    func hidesTabChrome() -> some View { modifier(HidesTabChrome()) }
}

/// iOS 16+: системное скрытие панели вкладок; iOS 14–15: прячем `UITabBar` напрямую.
struct HidesTabChrome: ViewModifier {
    @EnvironmentObject private var env: AppEnvironment

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16.0, *) {
                content.toolbar(.hidden, for: .tabBar)
            } else {
                content.background(TabBarHider())
            }
        }
        .onAppear { env.chromeHiders += 1 }
        .onDisappear { env.chromeHiders = max(0, env.chromeHiders - 1) }
    }
}

private struct TabBarHider: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            tabBarController?.tabBar.isHidden = true
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            tabBarController?.tabBar.isHidden = false
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
}

/// Экран, на который ведёт ссылка приложения или Spotify.
struct LinkTargetScreen: View {
    let target: AppLinks.Target

    var body: some View {
        switch target.kind {
        case .album: SpotifyAlbumScreen(albumId: target.id, name: target.title ?? "")
        case .playlist: SpotifyPlaylistScreen(playlistId: target.id, name: target.title ?? "")
        case .artist: SpotifyArtistScreen(artistId: target.id, name: target.title ?? "")
        case .track: LinkedTrackScreen(target: target)
        }
    }
}

/// Трек по ссылке: показывает его и даёт запустить.
struct LinkedTrackScreen: View {
    let target: AppLinks.Target
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var loader = Loader<SpotifyTrack>()

    var body: some View {
        List {
            if let t = loader.value {
                SpotifyHeader(imageUrl: t.album?.images.best(minWidth: 300), title: t.name, subtitle: t.artistNames, detail: t.album?.name)
                PlayShuffleRow(tracks: [t], queueTitle: t.name)
                SpotifyTrackRow(track: t, queueTitle: t.name)
            } else if case .failed(let message) = loader.state {
                LoadStatusRow(isLoading: false, error: message, retry: { load(force: true) })
            } else {
                LoadStatusRow(isLoading: true, error: nil, retry: {})
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle(target.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        let api = env.spotify
        let id = target.id
        loader.load(force: force) { try await api.track(id) }
    }
}

/// Число непрочитанных на вкладке (`badge` есть только с iOS 15).
struct UnreadBadge: ViewModifier {
    let count: Int

    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content.badge(count)
        } else {
            content
        }
    }
}

/// Значки в шапке главной и библиотеки, как на Android: история, «Вместе» (с числом непрочитанных), интеграции, настройки.
struct TopBarIcons: View {
    var together: Binding<Bool>?
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chats: ChatHub
    @State private var localTogether = false

    var body: some View {
        HStack(spacing: UIMetrics.isNarrow ? 12 : 16) {
            NavigationLink(destination: HistoryScreen()) { Image(systemName: "clock.arrow.circlepath") }
            NavigationLink(destination: TogetherScreen(), isActive: together ?? $localTogether) {
                Image(systemName: "person.2")
                    .overlay(badge, alignment: .topTrailing)
            }
            NavigationLink(destination: IntegrationsScreen(settings: env.prefs.settings)) { Image(systemName: "puzzlepiece") }
            NavigationLink(destination: SettingsScreen()) { Image(systemName: "gearshape") }
        }
        .font(.system(size: 17, weight: .regular))
    }

    @ViewBuilder private var badge: some View {
        if chats.unreadTotal > 0 {
            Text("\(min(chats.unreadTotal, 99))")
                .font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Color.red))
                .offset(x: 9, y: -7)
        }
    }
}

/// Лист на половину экрана с iOS 16 (как нижний лист Android), раньше — обычный.
struct MediumSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        } else {
            content
        }
    }
}
