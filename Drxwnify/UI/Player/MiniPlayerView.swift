import SwiftUI
import UIKit

/// Мини-плеер над навигацией (UI-051): тап разворачивает полный плеер, свайп в стороны листает треки.
struct MiniPlayerView: View {
    enum Style { case classic, accessory }

    static let classicHeight: CGFloat = 64

    let style: Style
    @Binding var showPlayer: Bool
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var likes: LikeManager
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        if player.current == nil {
            if style == .accessory {
                Text(L("mini_player_nothing")).font(.subheadline).foregroundColor(.secondary)
            }
        } else {
            switch style {
            case .classic:
                row
                    .padding(.leading, 6).padding(.trailing, 8)
                    .frame(height: Self.classicHeight)
                    .background(BlurView(style: .systemChromeMaterial))
                    .clipShape(Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            case .accessory:
                row.padding(.horizontal, 8)
            }
        }
    }

    private var fraction: CGFloat {
        guard player.duration > 0 else { return 0 }
        let f: Double = player.position / player.duration
        return CGFloat(min(1.0, max(0.0, f)))
    }

    /// Как на Android: круглая обложка с кольцом прогресса, по центру — пауза/играть.
    private var playDisc: some View {
        let side: CGFloat = style == .classic ? 52 : 36
        let inner: CGFloat = side - 6
        return Button(action: player.togglePlayPause) {
            ZStack {
                ArtworkView(url: player.current?.artworkUrl, size: inner, circle: true)
                Circle().fill(Color.black.opacity(0.35)).frame(width: inner, height: inner)
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5).frame(width: side, height: side)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: side, height: side)
                if player.isLoading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: style == .classic ? 18 : 13, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(width: side + 2, height: side + 2)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var row: some View {
        HStack(spacing: 10) {
            playDisc
            HStack(spacing: 0) {
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

            if style == .classic {
                FollowArtistButton(artistId: player.current?.artists.first?.id)
                downloadButton
                Button(action: toggleLike) { circleLabel(isLiked ? "heart.fill" : "heart", tint: isLiked ? .red : .primary) }
            } else {
                Button(action: toggleLike) { Image(systemName: isLiked ? "heart.fill" : "heart").foregroundColor(isLiked ? .red : .primary) }
            }
        }
        .foregroundColor(.primary)
    }

    private var isLiked: Bool { player.current.map(likes.isLiked) ?? false }

    private func toggleLike() {
        guard let t = player.current else { return }
        likes.toggle(t)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @ViewBuilder private var downloadButton: some View {
        if let t = player.current {
            switch downloads.states[t.id] {
            case .done:
                Button(action: { downloads.remove([t.id]) }) { circleLabel("arrow.down.circle.fill", tint: .accentColor) }
            case .downloading(let p):
                Button(action: { downloads.cancel(t.id) }) {
                    ZStack {
                        circleLabel("xmark", tint: .secondary)
                        Circle().trim(from: 0, to: CGFloat(p)).stroke(Color.accentColor, lineWidth: 2)
                            .rotationEffect(.degrees(-90)).frame(width: 40, height: 40)
                    }
                }
            case .queued, .resolving:
                Button(action: { downloads.cancel(t.id) }) { circleLabel("xmark", tint: .secondary) }
            default:
                Button(action: { downloads.download([t]) }) { circleLabel("arrow.down.to.line", tint: .primary) }
            }
        }
    }
}

/// Кружок-кнопка мини-плеера (обводка, как на Android).
func circleLabel(_ symbol: String, tint: Color) -> some View {
    Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(tint)
        .frame(width: 40, height: 40)
        .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
}

/// Подписка на исполнителя играющего трека (значок человека в мини-плеере Android).
struct FollowArtistButton: View {
    let artistId: String?
    @EnvironmentObject private var env: AppEnvironment
    @State private var following: Bool?
    private static var cache: [String: Bool] = [:]

    var body: some View {
        Button(action: toggle) {
            circleLabel(following == true ? "person.fill.checkmark" : "person", tint: following == true ? .accentColor : .primary)
        }
        .disabled(artistId == nil || following == nil)
        .opacity(artistId == nil ? 0.4 : 1)
        .onAppear(perform: load)
        .onChange(of: artistId) { _ in load() }
    }

    private func load() {
        guard let id = artistId, !id.isEmpty else { following = nil; return }
        if let v = Self.cache[id] { following = v; return }
        following = nil
        let api = env.spotify
        Task {
            let v = (try? await api.isFollowingArtist(id)) ?? false
            await MainActor.run {
                Self.cache[id] = v
                if artistId == id { following = v }
            }
        }
    }

    private func toggle() {
        guard let id = artistId, let now = following else { return }
        following = !now
        Self.cache[id] = !now
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let api = env.spotify
        Task {
            do {
                try await api.setFollowingArtist(id, follow: !now)
            } catch {
                await MainActor.run {
                    Self.cache[id] = now
                    if artistId == id { following = now }
                }
            }
        }
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
