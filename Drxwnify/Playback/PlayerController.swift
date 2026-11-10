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

    /// Этап 2: только показывает трек в мини-плеере, звук появится на этапе 3.
    func play(_ track: SpotifyTrack) {
        nowPlaying = NowPlaying(title: track.name, artist: track.artistNames)
        isPlaying = true
    }

    func skipNext() {}
}
