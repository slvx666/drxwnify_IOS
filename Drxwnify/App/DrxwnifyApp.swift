import SwiftUI

@main
struct DrxwnifyApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.player)
                .preferredColorScheme(.dark)
        }
    }
}
