import SwiftUI

enum AppTab: Hashable {
    case home, search, together, library
}

/// Корень: 4 вкладки (UI-001) и мини-плеер над навигацией (UI-051).
struct RootView: View {
    @State private var tab: AppTab = .home

    /// Высота стандартной панели вкладок над безопасной зоной (iOS 14–25).
    static let classicTabBarHeight: CGFloat = 49

    var body: some View {
        if #available(iOS 26.0, *) {
            tabs
                .tabViewBottomAccessory {
                    MiniPlayerView(style: .accessory)
                }
        } else {
            ZStack(alignment: .bottom) {
                tabs
                MiniPlayerView(style: .classic)
                    .padding(.bottom, Self.classicTabBarHeight)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
}
