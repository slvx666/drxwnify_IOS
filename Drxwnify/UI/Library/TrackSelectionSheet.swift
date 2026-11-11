import SwiftUI

/// Выделение треков (Android 2.0.2–2.2.5, `ui/component/TrackSelection.kt`): галочки, «Выбрать все»,
/// действия «В плейлист», «В очередь», «Скачать», «Запретить / Разрешить», «Отправить».
struct TrackSelectionSheet: View {
    let tracks: [Track]
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var blocked = BlockedTracks.shared
    @Environment(\.presentationMode) private var presentation
    @State private var selected = Set<Int>()
    @State private var shareItems: [Any]?
    @State private var filesToSave: [URL]?
    @State private var notice: String?

    private var picked: [Track] { selected.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
    private var allBlocked: Bool { !picked.isEmpty && picked.allSatisfy(blocked.isBlocked) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        Button(action: { toggle(i) }) {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(i) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundColor(selected.contains(i) ? .accentColor : .secondary)
                                ArtworkView(url: t.artworkUrl, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).lineLimit(1)
                                    Text(t.artistNames).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if blocked.isBlocked(t) { Image(systemName: "nosign").foregroundColor(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .listStyle(PlainListStyle())
                actionBar
            }
            .navigationTitle(selected.isEmpty ? L("ios_select_tracks") : LPlural("n_song", selected.count))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(L("close")) { presentation.wrappedValue.dismiss() },
                trailing: HStack(spacing: 16) {
                    Button(selected.count == tracks.count ? L("ios_select_none") : L("ios_select_all")) {
                        selected = selected.count == tracks.count ? [] : Set(tracks.indices)
                    }
                    exportMenu
                })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
        .background(EmptyView().sheet(isPresented: Binding(get: { filesToSave != nil }, set: { if !$0 { filesToSave = nil } })) {
            ExportToFiles(urls: filesToSave ?? [])
        })
        .alert(isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Alert(title: Text(notice ?? ""))
        }
    }

    /// Выбранные, а если ничего не выбрано — все.
    private var scope: [Track] { selected.isEmpty ? tracks : picked }

    /// Экспорт (DL-004, DL-012, DL-016): файлы скачанного — отправить или сохранить в «Файлы»; список — CSV или M3U.
    private var exportMenu: some View {
        Menu {
            Button(action: { shareDownloaded(toFiles: false) }) { Label(L("ios_send_files"), systemImage: "square.and.arrow.up") }
            Button(action: { shareDownloaded(toFiles: true) }) { Label(L("ios_save_to_files"), systemImage: "folder") }
            Button(action: { exportList("csv") }) { Label(L("ios_export_csv"), systemImage: "tablecells") }
            Button(action: { exportList("m3u") }) { Label(L("ios_export_m3u"), systemImage: "music.note.list") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func shareDownloaded(toFiles: Bool) {
        let urls = downloads.exportCopies(scope)
        if urls.isEmpty { notice = L("ios_no_downloaded_selected"); return }
        if toFiles { filesToSave = urls } else { shareItems = urls }
    }

    private func exportList(_ ext: String) {
        let text = ext == "csv" ? PlaylistExporter.csv(scope) : PlaylistExporter.m3u(scope)
        if let url = PlaylistExporter.file(text, name: "Drxwnify", ext: ext) { shareItems = [url] }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            action(L("ios_to_playlist"), "text.badge.plus") {
                let t = picked
                presentation.wrappedValue.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { env.addToPlaylist = TrackBatch(tracks: t) }
            }
            action(L("add_to_queue"), "text.append") { player.addToQueue(picked); presentation.wrappedValue.dismiss() }
            action(L("action_download"), "arrow.down.to.line") { downloads.download(picked); presentation.wrappedValue.dismiss() }
            action(L(allBlocked ? "ios_unblock" : "ios_block"), allBlocked ? "checkmark.circle" : "nosign") {
                blocked.set(picked, blocked: !allBlocked)
            }
            action(L("ios_send"), "arrowshape.turn.up.right") {
                let lines = picked.map { AppLinks.trackLink(mediaId: $0.id, title: $0.title, by: $0.artistNames) ?? "\($0.artistNames) — \($0.title)" }
                shareItems = [lines.joined(separator: "\n\n")]
            }
        }
        .disabled(selected.isEmpty)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .foregroundColor(selected.isEmpty ? .secondary : .primary)
    }

    private func toggle(_ i: Int) {
        if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
    }
}
