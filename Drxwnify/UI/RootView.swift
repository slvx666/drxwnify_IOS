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
            .onAppear {
                env.currentTab = Self.name(tab)
                runDebugScreen()
            }
            .background(EmptyView().sheet(isPresented: Binding(get: { env.debugSheet != nil }, set: { if !$0 { env.debugSheet = nil } })) {
                NavigationView { debugSheetContent }
                    .navigationViewStyle(StackNavigationViewStyle())
                    .environmentObject(env).environmentObject(player).environmentObject(env.likes)
                    .environmentObject(env.downloads).environmentObject(env.friends).environmentObject(env.chats)
                    .preferredColorScheme(.dark)
                    .modifier(ThemedRoot(theme: AppTheme.current))
            })
            .onChange(of: tab) { env.currentTab = Self.name($0) }
            .onChange(of: env.homeRequest) { _ in
                showPlayer = false
                tab = .home
            }
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
                    LinkTargetScreen(target: target, onClose: { env.linkTarget = nil })
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
                    .modifier(ThemedRoot(theme: AppTheme.current))
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
                    .modifier(ThemedRoot(theme: AppTheme.current))
                    .modifier(MediumSheet())
            })
            .background(EmptyView().sheet(item: $env.trackSelection) { batch in
                TrackSelectionSheet(tracks: batch.tracks)
                    .environmentObject(env)
                    .environmentObject(player)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
                    .modifier(ThemedRoot(theme: AppTheme.current))
            })
            .background(EmptyView().sheet(item: $env.addToPlaylist) { batch in
                AddToPlaylistSheet(batch: batch)
                    .environmentObject(env)
                    .environmentObject(env.downloads)
                    .preferredColorScheme(.dark)
                    .modifier(ThemedRoot(theme: AppTheme.current))
            })
            .background(EmptyView().sheet(item: Binding(get: { suggestions.replies.first }, set: { _ in })) { reply in
                SuggestionReplySheet(reply: reply).preferredColorScheme(.dark)
                    .modifier(ThemedRoot(theme: AppTheme.current))
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
                    .modifier(ThemedRoot(theme: AppTheme.current))
            }
    }

    @ViewBuilder private var content: some View {
        if #available(iOS 26.0, *) {
            tabs
                .tabViewBottomAccessory {
                    MiniPlayerView(style: .accessory, showPlayer: $showPlayer)
                }
        } else {
            // iOS 14–25: своя нижняя панель вместо системной — капсула размером с мини-плеер; на экранах-деталях
            // уходит сразу в начале перехода, и мини-плеер встаёт на её место (как на Android).
            ZStack(alignment: .bottom) {
                ZStack {
                    tabPage(HomeScreen().tabRoot("home")).opacity(tab == .home ? 1 : 0).allowsHitTesting(tab == .home).accessibilityHidden(tab != .home)
                    tabPage(SearchScreen().tabRoot("search")).opacity(tab == .search ? 1 : 0).allowsHitTesting(tab == .search).accessibilityHidden(tab != .search)
                    tabPage(LibraryScreen().tabRoot("library")).opacity(tab == .library ? 1 : 0).allowsHitTesting(tab == .library).accessibilityHidden(tab != .library)
                }
                VStack(spacing: 0) {
                    if !env.chatOpen {
                        MiniPlayerView(style: .classic, showPlayer: $showPlayer)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !env.chromeHidden {
                        CapsuleTabBar(tab: $tab)
                            .padding(.top, 2)
                            .transition(.move(edge: .bottom))
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .animation(.easeInOut(duration: 0.25), value: env.chromeHidden)
            .animation(.easeOut(duration: 0.2), value: env.chatOpen)
        }
    }

    /// `DRX_SCREEN`: `home|search|library`, `search:<запрос>`, `library:<фильтр>`, `player`, `queue`,
    /// `album:<id>`, `artist:<id>`, `playlist:<id>`, `settings`, `integrations`, `together`, `stats`, `history`.
    private func runDebugScreen() {
        guard let raw = ProcessInfo.processInfo.environment["DRX_SCREEN"], !raw.isEmpty else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts[0], arg = parts.count > 1 ? parts[1] : ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            switch key {
            case "home": tab = .home
            case "search":
                tab = .search
                if !arg.isEmpty { env.debugSearch = arg }
            case "library":
                tab = .library
                if !arg.isEmpty { env.debugLibraryFilter = arg }
            case "player": showPlayer = true
            case "album": env.linkTarget = AppLinks.Target(kind: .album, id: arg, title: nil, by: nil)
            case "artist": env.linkTarget = AppLinks.Target(kind: .artist, id: arg, title: nil, by: nil)
            case "playlist": env.linkTarget = AppLinks.Target(kind: .playlist, id: arg, title: nil, by: nil)
            default: env.debugSheet = key
            }
        }
    }

    @ViewBuilder private var debugSheetContent: some View {
        switch env.debugSheet ?? "" {
        case "settings": SettingsScreen()
        case "integrations": IntegrationsScreen(settings: env.prefs.settings)
        case "together": TogetherScreen()
        case "stats": StatsScreen()
        case "history": HistoryScreen()
        case "concerts": List { ConcertsSection() }.listStyle(PlainListStyle())
        default: Text(env.debugSheet ?? "")
        }
    }

    static func name(_ t: AppTab) -> String {
        switch t {
        case .home: return "home"
        case .search: return "search"
        case .library: return "library"
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
        // Фон экрана — цвет темы: иначе под строкой поиска, фишками и т. п. просвечивает системный чёрный.
        NavigationView { content.background(AppTheme.rowBackground.ignoresSafeArea()) }
            .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// Отступ снизу под мини-плеер и свою нижнюю панель (на iOS 26 система делает это сама).
struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            // Постоянный отступ (мини-плеер + панель): если менять его вместе с панелью, список дёргается при переходе.
            content.padding(.bottom, MiniPlayerView.classicHeight + 8 + CapsuleTabBar.height)
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
    /// Прячет нижнюю панель, пока экран открыт (детали, «Вместе», чат).
    func hidesTabChrome() -> some View { modifier(HidesTabChrome()) }
}

/// iOS 26: системное скрытие панели вкладок. iOS 14–25: счётчик для своей панели, который меняется
/// в `viewWillAppear` / `viewWillDisappear` — то есть в самом начале перехода, а не после него.
struct HidesTabChrome: ViewModifier {
    @EnvironmentObject private var env: AppEnvironment

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar(.hidden, for: .tabBar)
                .onAppear { env.chromeHiders += 1 }
                .onDisappear { env.chromeHiders = max(0, env.chromeHiders - 1) }
        } else {
            content.background(ChromeSignal(change: { delta in
                env.chromeHiders = max(0, env.chromeHiders + delta)
            }))
        }
    }
}

extension View {
    /// Корень вкладки: пока он на экране, нижняя панель видна.
    func tabRoot(_ name: String) -> some View { modifier(TabRootSignal(name: name)) }
}

struct TabRootSignal: ViewModifier {
    let name: String
    @EnvironmentObject private var env: AppEnvironment

    func body(content: Content) -> some View {
        content
            .background(ChromeSignal(change: { delta in
                if delta > 0 { env.rootVisible.insert(name) } else { env.rootVisible.remove(name) }
            }))
            // В поиске шапка стоит: жест «прятать при прокрутке» там мешает нажатиям по фишкам и строке поиска.
            .background(BarsOnSwipe(enabled: name != "search"))
    }
}

/// Верхняя панель (история, «Вместе», интеграции, настройки) уходит при прокрутке вниз и возвращается
/// при прокрутке вверх, как на Android; только на корне вкладки — на вложенных экранах шапка стоит.
private struct BarsOnSwipe: UIViewControllerRepresentable {
    var enabled = true

    final class Controller: UIViewController {
        var enabled = true
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.hidesBarsOnSwipe = enabled
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.hidesBarsOnSwipe = false
            navigationController?.setNavigationBarHidden(false, animated: true)
        }
    }
    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.enabled = enabled
        return c
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enabled = enabled }
}

private struct ChromeSignal: UIViewControllerRepresentable {
    let change: (Int) -> Void

    final class Controller: UIViewController {
        var change: ((Int) -> Void)?
        private var counted = false
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !counted { counted = true; change?(1) }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if counted { counted = false; change?(-1) }
        }
    }
    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.change = change
        return c
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.change = change }
}

/// Своя нижняя панель (вместо системной, чтобы прятать её сразу и плавно): во всю ширину, как системная.
struct CapsuleTabBar: View {
    @Binding var tab: AppTab
    static var height: CGFloat { UIMetrics.isNarrow ? 52 : 56 }

    var body: some View {
        HStack(spacing: 0) {
            item(.home, L("home"), "house.fill")
            item(.search, L("search"), "magnifyingglass")
            item(.library, L("filter_library"), "music.note.list")
        }
        .frame(height: Self.height)
        // Как системная панель: во всю ширину до краёв и до низа экрана, материал iOS и линия сверху.
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5), alignment: .top)
    }

    private func item(_ t: AppTab, _ title: String, _ symbol: String) -> some View {
        Button(action: {
            if tab != t { UISelectionFeedbackGenerator().selectionChanged() }
            tab = t
        }) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                    .frame(height: 26)
                Text(title).font(.system(size: 10, weight: tab == t ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundColor(tab == t ? .accentColor : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Возврат свайпом от края работает и там, где системная шапка спрятана (экран исполнителя).
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// Экран, на который ведёт ссылка приложения или Spotify.
struct LinkTargetScreen: View {
    let target: AppLinks.Target
    /// Закрыть лист (у исполнителя своя кнопка «назад» вместо шапки).
    var onClose: (() -> Void)? = nil

    var body: some View {
        switch target.kind {
        case .album: SpotifyAlbumScreen(albumId: target.id, name: target.title ?? "")
        case .playlist: SpotifyPlaylistScreen(playlistId: target.id, name: target.title ?? "")
        case .artist: SpotifyArtistScreen(artistId: target.id, name: target.title ?? "", onClose: onClose)
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

/// Шапка вкладки как на Android: название слева в одной строке со значками справа (без крупного заголовка iOS).
struct RootTitleBar<Trailing: View>: ViewModifier {
    let title: String
    let trailing: Trailing

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(title).font(.system(size: UIMetrics.isNarrow ? 22 : 24, weight: .bold)).lineLimit(1).fixedSize()
                }
                ToolbarItem(placement: .navigationBarTrailing) { trailing }
            }
    }
}

extension View {
    func rootTitle<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        modifier(RootTitleBar(title: title, trailing: trailing()))
    }
}
