import SwiftUI
import UIKit

/// Мини-плеер над навигацией (UI-051): тап разворачивает полный плеер, свайп в стороны листает треки.
struct MiniPlayerView: View {
    enum Style { case classic, accessory }

    static let classicHeight: CGFloat = 56

    let style: Style
    @Binding var showPlayer: Bool
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        if player.current == nil {
            if style == .accessory {
                Text(L("mini_player_nothing")).font(.subheadline).foregroundColor(.secondary)
            }
        } else {
            switch style {
            case .classic:
                row
                    .padding(.horizontal, 10)
                    .frame(height: Self.classicHeight)
                    .background(BlurView(style: .systemChromeMaterial))
                    .overlay(progress, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            case .accessory:
                row.padding(.horizontal, 12)
            }
        }
    }

    private var progress: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * CGFloat(player.duration > 0 ? min(1, player.position / player.duration) : 0), height: 2)
        }
        .frame(height: 2)
    }

    private var row: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(url: player.current?.artworkUrl, size: 40, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(player.errorText ?? player.current?.artistNames ?? "")
                        .font(.caption)
                        .foregroundColor(player.errorText == nil ? .secondary : .red)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { showPlayer = true }
            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                if abs(g.translation.width) > abs(g.translation.height) {
                    if g.translation.width < -40 { player.skipNext() }
                    if g.translation.width > 40 { player.skipPrevious() }
                } else if g.translation.height < -30 {
                    showPlayer = true
                }
            })

            Button(action: player.togglePlayPause) {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                }
                .frame(width: 40, height: 40)
            }
            Button(action: player.skipNext) {
                Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 40)
            }
            .disabled(!player.hasNext)
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
