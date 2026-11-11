import SwiftUI

enum AppTab: Hashable {
    case home, search, together, library
}

/// Корень: 4 вкладки (UI-001) и мини-плеер над навигацией (UI-051).
struct RootView: View {
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController

    /// Высота стандартной панели вкладок над безопасной зоной (iOS 14–25).
    static let classicTabBarHeight: CGFloat = 49

    var body: some View {
        content
            .onOpenURL { url in
                if env.friends.openInvite(url) { tab = .together; return }
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
            .background(EmptyView().sheet(item: $env.addToPlaylist) { batch in
                AddToPlaylistSheet(batch: batch)
                    .environmentObject(env)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
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
                if !env.chromeHidden {
                    MiniPlayerView(style: .classic, showPlayer: $showPlayer)
                        .padding(.bottom, Self.classicTabBarHeight)
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
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
            tabPage(TogetherScreen())
                .tabItem { Label(L("together"), systemImage: "person.2.fill") }
                .modifier(UnreadBadge(count: env.chats.unreadTotal))
                .tag(AppTab.together)
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
    /// Прячет мини-плеер и панель вкладок, пока экран открыт (чат).
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
        .onAppear { env.chromeHidden = true }
        .onDisappear { env.chromeHidden = false }
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
