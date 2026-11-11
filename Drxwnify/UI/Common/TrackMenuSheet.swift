import SwiftUI

/// Запрос меню трека из любого списка (лист открывает `RootView`).
struct TrackMenuRequest: Identifiable {
    let id = UUID()
    let track: Track
}

/// Меню трека нижним листом, как `ui/menu/PlayerMenu.kt` / `SongMenu`: шапка с обложкой и лайком,
/// дальше карточки пунктов в порядке Android.
struct TrackMenuSheet: View {
    let track: Track
    /// Трек сейчас играет: показывать «Изменить версию трека».
    var isCurrent = false
    /// Переход к альбому или исполнителю (лист закрывается, экран открывает вызывающий).
    let navigate: (AppLinks.Target) -> Void
    var addToPlaylist: (() -> Void)?
    var changeVersion: (() -> Void)?

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var likes: LikeManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.presentationMode) private var presentation
    @State private var shareItems: [Any]?
    @State private var showInfo = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 36, height: 4).padding(.top, 8)
                header
                group {
                    item(L("add_to_queue"), "text.append") { player.addToQueue([track]); close() }
                    item(L("queue_play_next"), "text.insert") { player.playNext([track]); close() }
                }
                group {
                    downloadItem
                    item(L(isLiked ? "like_remove_spotify" : "like_add_spotify"), isLiked ? "heart.slash" : "heart") {
                        likes.toggle(track)
                    }
                    item(L("add_to_playlist"), "text.badge.plus") { close(then: addToPlaylist) }
                    item(L("track_info"), "info.circle", subtitle: L("details_desc")) { showInfo = true }
                    item(L("share"), "arrowshape.turn.up.right") {
                        shareItems = [AppLinks.trackLink(mediaId: track.id, title: track.title, by: track.artistNames) ?? "\(track.artistNames) — \(track.title)"]
                    }
                    if downloads.fileURL(track.id) != nil {
                        item(L("ios_send_files"), "doc.badge.arrow.up") { shareItems = downloads.exportCopies([track]) }
                    }
                    ForEach(track.artists.filter { !($0.id ?? "").isEmpty }, id: \.self) { a in
                        item(L("view_artist"), "person", subtitle: a.name) {
                            go(AppLinks.Target(kind: .artist, id: a.id ?? "", title: a.name, by: nil))
                        }
                    }
                    if let albumId = track.albumId, !albumId.isEmpty, track.catalogId != nil {
                        item(L("view_album"), "square.stack", subtitle: track.albumName) {
                            go(AppLinks.Target(kind: .album, id: albumId, title: track.albumName, by: nil))
                        }
                    }
                    if isCurrent, let change = changeVersion {
                        item(L("track_version"), "arrow.triangle.2.circlepath", subtitle: L("track_version_desc")) { close(then: change) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
        .background(EmptyView().sheet(isPresented: $showInfo) {
            TrackInfoScreen(track: track, isCurrent: isCurrent).environmentObject(player).environmentObject(downloads)
        })
        .onAppear { likes.refresh([track]) }
    }

    private var isLiked: Bool { likes.isLiked(track) }

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkUrl, size: 56, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artistNames).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { likes.toggle(track); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
                Image(systemName: isLiked ? "heart.fill" : "heart").font(.title2).foregroundColor(isLiked ? .red : .primary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var downloadItem: some View {
        switch downloads.states[track.id] {
        case .done:
            item(L("remove_download"), "trash") { downloads.remove([track.id]) }
        case .downloading(let p):
            item("\(L("cancel_download")) · \(Int(p * 100))%", "xmark.circle") { downloads.cancel(track.id) }
        case .queued, .resolving:
            item(L("cancel_download"), "xmark.circle") { downloads.cancel(track.id) }
        default:
            item(downloadTitle, "arrow.down.to.line") { downloads.download([track]); close() }
        }
    }

    /// «Загрузить (VK · MP3 · 320 kbps)» для играющего трека, как на Android.
    private var downloadTitle: String {
        if isCurrent, let m = player.serving, let s = player.servingStream {
            let codec = s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased()
            return "\(L("action_download")) (\(m.provider.displayName) · \(codec) · \(s.bitrate / 1000) kbps)"
        }
        return L("action_download")
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2) { content() }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func item(_ title: String, _ symbol: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).multilineTextAlignment(.leading)
                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func close(then action: (() -> Void)? = nil) {
        presentation.wrappedValue.dismiss()
        if let action = action {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
        }
    }

    private func go(_ target: AppLinks.Target) {
        close { navigate(target) }
    }
}

/// «Информация о треке»: сначала качество звука (как на Android 1.3.0), потом сведения.
struct TrackInfoScreen: View {
    let track: Track
    var isCurrent = false
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            List {
                if isCurrent, let s = player.servingStream {
                    Section(header: Text(L("ios_track_info_audio"))) {
                        row(L("ios_track_info_source"), player.servingLocal ? L("ios_downloaded") : (player.serving?.provider.displayName ?? "—"))
                        row(L("ios_track_info_codec"), s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased())
                        row(L("ios_track_info_bitrate"), "\(s.bitrate / 1000) kbps")
                    }
                }
                Section {
                    row(L("ios_track_info_title"), track.title)
                    row(L("ios_track_info_artists"), track.artistNames)
                    if let album = track.albumName, !album.isEmpty { row(L("ios_track_info_album"), album) }
                    if track.durationMs > 0 { row(L("ios_track_info_duration"), formatDuration(ms: track.durationMs)) }
                    if let id = track.catalogId { row("Spotify ID", id) }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("track_info"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .contextMenu {
            Button(action: { UIPasteboard.general.string = value }) { Label(L("ios_copy"), systemImage: "doc.on.doc") }
        }
    }
}

/// Кнопка «⋮» в строке трека: открывает меню трека (как на Android).
struct TrackMoreButton: View {
    let track: Track
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Button(action: { env.trackMenu = TrackMenuRequest(track: track) }) {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(BorderlessButtonStyle())
    }
}
