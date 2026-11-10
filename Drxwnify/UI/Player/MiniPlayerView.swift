import SwiftUI
import UIKit

/// Мини-плеер (UI-051). На этапе 0 — заглушка без звука.
struct MiniPlayerView: View {
    enum Style { case classic, accessory }

    static let classicHeight: CGFloat = 56

    let style: Style
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        switch style {
        case .classic:
            row
                .padding(.horizontal, 12)
                .frame(height: Self.classicHeight)
                .background(BlurView(style: .systemChromeMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        case .accessory:
            row.padding(.horizontal, 12)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "music.note").foregroundColor(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowPlaying?.title ?? L("mini_player_nothing"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = player.nowPlaying?.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            Button(action: player.skipNext) {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 36, height: 40)
            }
        }
        .foregroundColor(.primary)
    }
}

/// Размытие UIKit: `Material` в SwiftUI есть только с iOS 15.
struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
