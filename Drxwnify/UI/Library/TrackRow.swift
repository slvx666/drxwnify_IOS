import SwiftUI

/// Пункты меню трека (долгое нажатие): общие для треков каталога и своей библиотеки.
struct TrackMenuItems: View {
    let track: Track
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var likes: LikeManager
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        Button(action: { player.playNext([track]) }) { Label(L("play_next"), systemImage: "text.insert") }
        Button(action: { player.addToQueue([track]) }) { Label(L("add_to_queue"), systemImage: "text.append") }
        Button(action: { env.addToPlaylist = TrackBatch(tracks: [track]) }) { Label(L("add_to_playlist"), systemImage: "text.badge.plus") }
        switch downloads.states[track.id] {
        case .done:
            Button(action: { downloads.remove([track.id]) }) { Label(L("remove_download"), systemImage: "trash") }
        case .queued, .resolving, .downloading:
            Button(action: { downloads.cancel(track.id) }) { Label(L("cancel_download"), systemImage: "xmark.circle") }
        default:
            Button(action: { downloads.download([track]) }) { Label(L("action_download"), systemImage: "arrow.down.circle") }
        }
        Button(action: { likes.toggle(track) }) {
            let on = likes.isLiked(track)
            Label(L(on ? "action_remove_like" : "action_like"), systemImage: on ? "heart.slash" : "heart")
        }
        if track.catalogId != nil, let albumId = track.albumId, !albumId.isEmpty {
            Button(action: { env.linkTarget = AppLinks.Target(kind: .album, id: albumId, title: track.albumName, by: nil) }) {
                Label(L("view_album"), systemImage: "square.stack")
            }
        }
        if track.catalogId != nil, let a = track.artists.first, let id = a.id, !id.isEmpty {
            Button(action: { env.linkTarget = AppLinks.Target(kind: .artist, id: id, title: a.name, by: nil) }) {
                Label(L("view_artist"), systemImage: "person")
            }
        }
        if let link = AppLinks.trackLink(mediaId: track.id, title: track.title, by: track.artistNames) {
            Button(action: { UIPasteboard.general.string = link.components(separatedBy: "\n").last }) {
                Label(L("copy_link"), systemImage: "link")
            }
        }
    }
}

/// Набор треков для листа «Добавить в плейлист».
struct TrackBatch: Identifiable {
    let id = UUID()
    var tracks: [Track]
}

/// Строка трека своей библиотеки.
struct TrackRow: View {
    let track: Track
    var context: [Track] = []
    var index = 0
    var queueTitle: String?
    var subtitle: String?

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var likes: LikeManager

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        Button(action: {
            if context.isEmpty { player.play([track], title: queueTitle) } else { player.play(context, startIndex: index, title: queueTitle) }
        }) {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkUrl, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body).lineLimit(1).foregroundColor(isCurrent ? .accentColor : .primary)
                    HStack(spacing: 4) {
                        if likes.liked.contains(track.id) {
                            Image(systemName: "heart.fill").font(.caption2).foregroundColor(.red)
                        }
                        DownloadBadge(trackId: track.id)
                        Text(subtitle ?? (track.durationMs > 0 ? "\(track.artistNames) • \(formatDuration(ms: track.durationMs))" : track.artistNames))
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                TrackMoreButton(track: track)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .modifier(BlockedLook(track: track))
        .contextMenu { TrackMenuItems(track: track) }
    }
}

/// «Играть» и «Перемешать» для списка треков библиотеки.
struct TrackPlayShuffleRow: View {
    let tracks: [Track]
    var queueTitle: String?
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        PlayButtonsRow(tracks: tracks,
                       play: { player.play(tracks, title: queueTitle, shuffled: false) },
                       shuffle: { player.play(tracks, title: queueTitle, shuffled: true) })
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

/// Лист «Добавить в плейлист»: свои плейлисты, отметка «уже в плейлисте», создание нового (LIB-016, LIB-018).
struct AddToPlaylistSheet: View {
    let batch: TrackBatch
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentation
    @State private var playlists: [LocalPlaylist] = []
    @State private var newName = ""
    @State private var duplicate: (playlist: LocalPlaylist, count: Int)?

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        TextField(L("playlist_name"), text: $newName)
                        Button(L("create_playlist")) {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            let id = env.library.createPlaylist(name: name)
                            env.library.add(batch.tracks, to: id)
                            presentation.wrappedValue.dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(playlists.filter { $0.isEditable }) { p in
                        Button(action: { add(to: p) }) {
                            HStack(spacing: 12) {
                                PlaylistCover(playlist: p, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundColor(.primary).lineLimit(1)
                                    Text(LPlural("n_song", p.songCount)).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("cancel")) { presentation.wrappedValue.dismiss() })
            .alert(isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } })) {
                let d = duplicate
                return Alert(
                    title: Text(L("duplicates")),
                    message: Text((d?.count ?? 1) > 1 ? L("duplicates_description_multiple", d?.count ?? 0) : L("duplicates_description_single")),
                    primaryButton: .default(Text(L("ios_add_anyway"))) {
                        if let p = d?.playlist { finish(p, batch.tracks) }
                    },
                    secondaryButton: .cancel(Text(L("ios_skip_duplicates"))) {
                        if let p = d?.playlist {
                            let existing = env.library.contained(in: p.id, batch.tracks.map { $0.id })
                            finish(p, batch.tracks.filter { !existing.contains($0.id) })
                        }
                    })
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear { playlists = env.library.playlists() }
    }

    private func add(to p: LocalPlaylist) {
        let existing = env.library.contained(in: p.id, batch.tracks.map { $0.id })
        if existing.isEmpty { finish(p, batch.tracks) } else { duplicate = (p, existing.count) }
    }

    private func finish(_ p: LocalPlaylist, _ tracks: [Track]) {
        env.library.add(tracks, to: p.id)
        presentation.wrappedValue.dismiss()
    }
}

/// Обложка своего плейлиста: своя картинка, мозаика из четырёх обложек треков или одна.
struct PlaylistCover: View {
    let playlist: LocalPlaylist
    var size: CGFloat = 48

    var body: some View {
        if playlist.thumbnailUrl == nil, playlist.thumbnails.count >= 4 {
            let half = size / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ArtworkView(url: playlist.thumbnails[0], size: half, cornerRadius: 0)
                    ArtworkView(url: playlist.thumbnails[1], size: half, cornerRadius: 0)
                }
                HStack(spacing: 0) {
                    ArtworkView(url: playlist.thumbnails[2], size: half, cornerRadius: 0)
                    ArtworkView(url: playlist.thumbnails[3], size: half, cornerRadius: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ArtworkView(url: playlist.thumbnailUrl ?? playlist.thumbnails.first, size: size, cornerRadius: 6, placeholderSymbol: "music.note.list")
        }
    }
}

/// Значок состояния загрузки в строке трека.
struct DownloadBadge: View {
    let trackId: String
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        switch downloads.states[trackId] {
        case .done:
            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundColor(.accentColor)
        case .queued, .resolving:
            Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
        case .downloading(let p):
            Text("\(Int(p * 100))%").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundColor(.orange)
        case .none:
            EmptyView()
        }
    }
}

/// «Скачать всё» для списка: скачать, отменить идущее или удалить скачанное.
struct DownloadAllButton: View {
    let tracks: [Track]
    @EnvironmentObject private var downloads: DownloadManager

    private var done: Int { tracks.filter { downloads.states[$0.id] == .done }.count }
    private var active: Int {
        tracks.filter {
            switch downloads.states[$0.id] {
            case .queued, .resolving, .downloading: return true
            default: return false
            }
        }.count
    }

    var body: some View {
        Button(action: {
            if active > 0 {
                tracks.forEach { downloads.cancel($0.id) }
            } else if done == tracks.count {
                downloads.remove(tracks.map { $0.id })
            } else {
                downloads.download(tracks)
            }
        }) {
            Group {
                if active > 0 {
                    Text("\(done)/\(tracks.count)").font(.caption.monospacedDigit())
                } else {
                    Image(systemName: done == tracks.count && !tracks.isEmpty ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
            }
            .font(.system(size: 20))
            .frame(width: 56, height: 56)
            .foregroundColor(done == tracks.count && !tracks.isEmpty ? .accentColor : .primary)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Кнопки под шапкой плейлиста, как на Android: «Перемешать» кружком, большая «Играть», «Скачать всё».
struct PlayButtonsRow: View {
    let tracks: [Track]
    let play: () -> Void
    let shuffle: () -> Void
    @EnvironmentObject private var env: AppEnvironment

    /// «Выбрать треки», как значок в шапке альбома на Android.
    private var selectButton: some View {
        Button(action: { env.trackSelection = TrackBatch(tracks: tracks) }) {
            Image(systemName: "checklist").font(.system(size: 17))
                .frame(width: 40, height: 40).foregroundColor(.secondary)
        }
        .buttonStyle(PlainButtonStyle())
    }

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            Button(action: shuffle) {
                Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .foregroundColor(.primary)
                    .background(Circle().fill(Color.secondary.opacity(0.2)))
            }
            .buttonStyle(PlainButtonStyle())
            Button(action: play) {
                Image(systemName: "play.fill").font(.system(size: 30, weight: .semibold))
                    .frame(width: 84, height: 84)
                    .foregroundColor(Color(.systemBackground))
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(PlainButtonStyle())
            DownloadAllButton(tracks: tracks)
            Spacer()
        }
        .overlay(selectButton, alignment: .trailing)
        .disabled(tracks.isEmpty)
        .padding(.vertical, 4)
    }
}

/// Запрещённый трек: блёклый, с ⊘ (Android 2.2.5).
struct BlockedLook: ViewModifier {
    let track: Track
    @ObservedObject private var blocked = BlockedTracks.shared

    func body(content: Content) -> some View {
        if blocked.isBlocked(track) {
            content.opacity(0.4).overlay(Image(systemName: "nosign").foregroundColor(.secondary).padding(.trailing, 40), alignment: .trailing)
        } else {
            content
        }
    }
}
