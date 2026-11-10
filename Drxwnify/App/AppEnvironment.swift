import Foundation
import Combine

/// Единая точка зависимостей приложения. Передаётся через `EnvironmentObject`.
final class AppEnvironment: ObservableObject {
    let player: PlayerController

    init() {
        self.player = PlayerController()
    }
}
