import SwiftUI

/// «⋯» альбома и плейлиста (UI-400…409, UI-500…513): системное меню с пунктами Android.
struct CollectionMenuButton: View {
    let tracks: [Track]
    let title: String
    /// Альбом: «Перейти к исполнителю».
    var artist: AppLinks.Target? = nil
    /// Плейлист: «Запустить радио».
    var radio = false
    var origin: PlayerController.Origin? = nil
    var refresh: (() -> Void)? = nil

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @State private var shareItems: [Any]?
    @State private var openArtist = false

    private var allDownloaded: Bool { !tracks.isEmpty && tracks.allSatisfy { downloads.states[$0.id] == .done } }

    var body: some View {
        Menu {
            Section {
                Button(action: { player.play(tracks, title: title, shuffled: false, origin: origin) }) { Label(L("play"), systemImage: "play") }
                Button(action: { player.play(tracks, title: title, shuffled: true, origin: origin) }) { Label(L("shuffle"), systemImage: "shuffle") }
                if radio, let seed = tracks.randomElement() {
                    Button(action: { player.play([seed], title: title + " · " + L("radio"), origin: .album) }) {
                        Label(L("start_radio"), systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
            Section {
                Button(action: { player.playNext(tracks) }) { Label(L("queue_play_next"), systemImage: "text.insert") }
                Button(action: { player.addToQueue(tracks) }) { Label(L("add_to_queue"), systemImage: "text.append") }
                Button(action: { env.addToPlaylist = TrackBatch(tracks: tracks) }) { Label(L("add_to_playlist"), systemImage: "text.badge.plus") }
            }
            Section {
                if allDownloaded {
                    Button(action: { downloads.remove(tracks.map { $0.id }) }) { Label(L("remove_download"), systemImage: "trash") }
                    Button(action: { shareItems = downloads.exportCopies(tracks) }) { Label(L("ios_send_files"), systemImage: "doc.badge.arrow.up") }
                } else {
                    Button(action: { downloads.download(tracks) }) { Label(L("action_download"), systemImage: "arrow.down.to.line") }
                }
                Button(action: { export("csv") }) { Label(L("ios_export_csv"), systemImage: "tablecells") }
                Button(action: { export("m3u") }) { Label(L("ios_export_m3u"), systemImage: "music.note.list") }
                Button(action: { env.trackSelection = TrackBatch(tracks: tracks) }) { Label(L("ios_select_tracks"), systemImage: "checklist") }
            }
            Section {
                if artist != nil {
                    Button(action: { openArtist = true }) { Label(L("view_artist"), systemImage: "person") }
                }
                if let r = refresh {
                    Button(action: r) { Label(L("refetch"), systemImage: "arrow.clockwise") }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 18))
        }
        .disabled(tracks.isEmpty)
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
        .background(NavigationLink(destination: SpotifyArtistScreen(artistId: artist?.id ?? "", name: artist?.title ?? ""),
                                   isActive: $openArtist) { EmptyView() }.opacity(0))
    }

    private func export(_ ext: String) {
        let text = ext == "csv" ? PlaylistExporter.csv(tracks) : PlaylistExporter.m3u(tracks)
        if let url = PlaylistExporter.file(text, name: title.isEmpty ? "Drxwnify" : title, ext: ext) { shareItems = [url] }
    }
}
