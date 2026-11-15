import SwiftUI

@main
struct DrxwnifyApp: App {
    @StateObject private var env = AppEnvironment()

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(ThemedRoot(theme: AppTheme.current))
                .id(env.languageVersion)
                .environmentObject(env)
                .environmentObject(env.player)
                .environmentObject(env.likes)
                .environmentObject(env.downloads)
                .environmentObject(env.friends)
                .environmentObject(env.chats)
                .preferredColorScheme(.dark)
                .onAppear {
                    BackgroundRefresh.chats = env.chats
                    TouchProbe.install()
                    ChangeWatch.watch("env", env.objectWillChange)
                    ChangeWatch.watch("player", env.player.objectWillChange)
                    ChangeWatch.watch("friends", env.friends.objectWillChange)
                    ChangeWatch.watch("chats", env.chats.objectWillChange)
                    ChangeWatch.watch("likes", env.likes.objectWillChange)
                    ChangeWatch.watch("downloads", env.downloads.objectWillChange)
                    ChangeWatch.watch("settings", env.prefs.settings.objectWillChange)
                    ChangeWatch.watch("feed", HomeFeed.shared.objectWillChange)
                    ChangeWatch.watch("suggestions", Suggestions.shared.objectWillChange)
                    env.chats.hold("foreground", true)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    // В фоне связь держит только играющая музыка (iOS иначе всё равно усыпит приложение).
                    env.chats.hold("foreground", false)
                    BackgroundRefresh.schedule()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // Открыли приложение: сообщения приходят сразу, а не только на экране «Вместе».
                    env.chats.hold("foreground", true)
                }
        }
    }
}
