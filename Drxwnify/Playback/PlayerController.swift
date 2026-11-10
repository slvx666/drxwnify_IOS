import Foundation
import Combine

/// Заглушка плеера (этап 0). Настоящий AVQueuePlayer появится на этапе 3.
final class PlayerController: ObservableObject {
    struct NowPlaying: Equatable {
        var title: String
        var artist: String
    }

    @Published var nowPlaying: NowPlaying?
    @Published var isPlaying = false

    func togglePlayPause() {
        if nowPlaying == nil {
            nowPlaying = NowPlaying(title: "Drxwnify", artist: L("mini_player_stub_artist"))
        }
        isPlaying.toggle()
    }

    func skipNext() {}
}
