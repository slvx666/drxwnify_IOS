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
    /// Список, из которого запущен трек: он становится очередью.
    var context: [SpotifyTrack] = []
    var index = 0
    var queueTitle: String?
    /// Альбом для треков, у которых его нет в ответе (экран альбома).
    var album: SpotifySimpleAlbum?
    /// Число прослушиваний Spotify в подписи (экран альбома, Android 2.1.5).
    var showPlayCount = false
    /// Что играет после очереди (альбом, топ артиста — радио).
    var origin: PlayerController.Origin?

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var likes: LikeManager
    @EnvironmentObject private var env: AppEnvironment

    private var isCurrent: Bool { player.current?.catalogId == track.id }

    private var subtitle: String {
        var parts = [track.artistNames]
        if track.durationMs > 0 { parts.append(formatDuration(ms: track.durationMs)) }
        if showPlayCount, let n = track.playCount, n > 0 {
            parts.append(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal))
        }
        return parts.joined(separator: " • ")
    }

    private func start() {
        if context.isEmpty {
            player.play([Track(track, album: album)], title: queueTitle)
        } else {
            player.play(context.map { Track($0, album: album) }, startIndex: index, title: queueTitle, origin: origin)
        }
    }

    var body: some View {
        Button(action: start) {
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
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                    HStack(spacing: 4) {
                        if likes.liked.contains(FallbackIds.of(track.id)) {
                            Image(systemName: "heart.fill").font(.caption2).foregroundColor(.red)
                        }
                        DownloadBadge(trackId: FallbackIds.of(track.id))
                        if track.explicit {
                            Image(systemName: "e.square.fill").font(.caption).foregroundColor(.secondary)
                        }
                        Text(subtitle)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                TrackMoreButton(track: Track(track, album: album))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .modifier(BlockedLook(track: Track(track, album: album)))
        .contextMenu { TrackMenuItems(track: Track(track, album: album)) }
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
            ArtworkView(url: imageUrl, size: min(220, UIMetrics.width * 0.6), cornerRadius: 12, circle: circle,
                        placeholderSymbol: circle ? "person.fill" : "music.note.list")
                .shadow(color: Color.black.opacity(0.4), radius: 14, y: 6)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
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

/// Кнопки «Играть» и «Перемешать» под шапкой списка.
struct PlayShuffleRow: View {
    let tracks: [SpotifyTrack]
    var queueTitle: String?
    var album: SpotifySimpleAlbum?
    /// Топ артиста: после него — его другие песни и похожие; «Перемешать» — все песни артиста без повторов (Android 2.2.5).
    var artistId: String?

    @EnvironmentObject private var player: PlayerController

    private func origin(shuffle: Bool) -> PlayerController.Origin? {
        if let id = artistId { return .artist(id, shuffleAll: shuffle) }
        return album != nil ? .album : nil
    }

    var body: some View {
        PlayButtonsRow(tracks: tracks.map { Track($0, album: album) },
                       play: { player.play(tracks.map { Track($0, album: album) }, title: queueTitle, shuffled: false, origin: origin(shuffle: false)) },
                       shuffle: { player.play(tracks.map { Track($0, album: album) }, title: queueTitle, shuffled: true, origin: origin(shuffle: true)) })
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
    }

    private func button(_ title: String, _ symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).fontWeight(.semibold)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(filled ? Color(.systemBackground) : .primary)
            .background(filled ? Color.primary : Color.secondary.opacity(0.2))
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Кнопка-переключатель, состояние которой хранится в аккаунте (подписка на артиста, альбом в библиотеке).
struct RemoteToggleButton: View {
    let onSymbol: String
    let offSymbol: String
    let onLabel: String
    let offLabel: String
    let read: () async throws -> Bool
    let write: (Bool) async throws -> Void

    @State private var isOn: Bool?
    @State private var busy = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn == true ? onSymbol : offSymbol)
                .foregroundColor(isOn == true ? .accentColor : .primary)
        }
        .disabled(isOn == nil || busy)
        .accessibility(label: Text(isOn == true ? onLabel : offLabel))
        .onAppear {
            guard isOn == nil else { return }
            Task {
                let value = (try? await read()) ?? false
                await MainActor.run { isOn = value }
            }
        }
    }

    private func toggle() {
        guard let current = isOn else { return }
        let target = !current
        isOn = target
        busy = true
        Task {
            let ok = (try? await write(target)) != nil
            await MainActor.run {
                if !ok { isOn = current }
                busy = false
            }
        }
    }
}

/// «Поделиться» ссылкой приложения.
struct ShareLinkButton: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button(action: { show = true }) { Image(systemName: "square.and.arrow.up") }
            .sheet(isPresented: $show) { ShareSheet(items: [text]) }
    }
}
