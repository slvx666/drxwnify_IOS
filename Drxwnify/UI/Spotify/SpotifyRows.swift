import SwiftUI

func formatDuration(ms: Int) -> String {
    let total = max(0, ms / 1000)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Строка трека каталога.
struct SpotifyTrackRow: View {
    let track: SpotifyTrack
    /// Номер вместо обложки (экран альбома).
    var number: Int?
    var showAlbumArt = true

    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Button(action: { player.play(track) }) {
            HStack(spacing: 12) {
                if let number = number {
                    Text("\(number)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 28)
                } else if showAlbumArt {
                    ArtworkView(url: track.album?.images.best(minWidth: 150), size: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).font(.body).lineLimit(1)
                    HStack(spacing: 4) {
                        if track.explicit {
                            Image(systemName: "e.square.fill").font(.caption).foregroundColor(.secondary)
                        }
                        Text(track.artistNames).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if track.durationMs > 0 {
                    Text(formatDuration(ms: track.durationMs))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Шапка плейлиста, альбома или артиста.
struct SpotifyHeader: View {
    let imageUrl: String?
    let title: String
    var subtitle: String?
    var detail: String?
    var circle = false

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(url: imageUrl, size: 180, cornerRadius: 10, circle: circle,
                        placeholderSymbol: circle ? "person.fill" : "music.note.list")
            Text(title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            if let detail = detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }
}

/// Горизонтальный ряд альбомов или артистов.
struct SpotifyShelf<Item: Identifiable, Destination: View>: View {
    let items: [Item]
    let imageUrl: (Item) -> String?
    let title: (Item) -> String
    let subtitle: (Item) -> String?
    var circle = false
    let destination: (Item) -> Destination

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(destination: destination(item)) {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(url: imageUrl(item), size: 124, cornerRadius: 8, circle: circle,
                                        placeholderSymbol: circle ? "person.fill" : "music.note")
                            Text(title(item)).font(.footnote).lineLimit(2)
                                .frame(width: 124, alignment: circle ? .center : .leading)
                                .multilineTextAlignment(circle ? .center : .leading)
                            if let sub = subtitle(item) {
                                Text(sub).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                    .frame(width: 124, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets())
    }
}
