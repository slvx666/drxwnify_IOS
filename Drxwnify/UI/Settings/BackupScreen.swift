import SwiftUI

/// Резервное копирование (SYS-200, SYS-201): копия в формате Android.
struct BackupScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    private enum Busy { case none, restoring, creating }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        /// Подтверждение «Восстановить?» для этого файла (иначе — просто сообщение).
        var confirm: URL? = nil
    }

    private struct SharedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var busy = Busy.none
    @State private var current = BackupManager.Summary()
    @State private var restored: BackupManager.Summary?
    @State private var showPicker = false
    @State private var notice: Notice?
    @State private var shared: SharedFile?
    /// Копии `.backup` в папке приложения («Файлы» → «На iPhone» → Drxwnify, или положенные с компьютера).
    @State private var found: [URL] = []

    var body: some View {
        List {
            Section(footer: Text(L("ios_backup_restore_note"))) {
                Button(action: { showPicker = true }) {
                    Label(L("action_restore"), systemImage: "square.and.arrow.down")
                }
                Button(action: createBackup) {
                    Label(L("action_backup"), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(busy != .none)

            if !found.isEmpty {
                Section(header: Text(L("ios_backup_found")), footer: Text(L("ios_backup_found_hint"))) {
                    ForEach(found, id: \.self) { url in
                        Button(action: { askRestore(url) }) {
                            Label(url.lastPathComponent, systemImage: "doc.zipper")
                        }
                    }
                }
                .disabled(busy != .none)
            }

            if busy != .none {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L(busy == .restoring ? "ios_backup_restoring" : "ios_backup_creating"))
                    }
                }
            }

            if let restored = restored {
                summarySection(L("ios_backup_in_file"), restored)
            }
            summarySection(L("ios_backup_now"), current)
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("backup_restore"))
        .miniPlayerInset()
        .onAppear(perform: reload)
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                // Алерт нельзя показать, пока закрывается лист выбора файла.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { askRestore(url) }
            }
        }
        .sheet(item: $shared) { file in
            ShareSheet(items: [file.url])
        }
        // Одно окно на экран: на iOS 14–16 из нескольких `.alert` работает только последний.
        .alert(item: $notice) { n in
            if let url = n.confirm {
                return Alert(
                    title: Text(n.title),
                    message: Text(n.text),
                    primaryButton: .destructive(Text(L("ios_restore"))) { restoreBackup(url) },
                    secondaryButton: .cancel()
                )
            }
            return Alert(title: Text(n.title), message: Text(n.text), dismissButton: .default(Text("OK")))
        }
    }

    private func askRestore(_ url: URL) {
        notice = Notice(title: L("ios_backup_restore_confirm_title"), text: L("ios_backup_restore_confirm_text"), confirm: url)
    }

    private func summarySection(_ title: String, _ s: BackupManager.Summary) -> some View {
        Section(header: Text(title)) {
            row(L("songs"), s.counts["song"])
            row(L("artists"), s.counts["artist"])
            row(L("albums"), s.counts["album"])
            row(L("playlists"), s.counts["playlist"])
            row(L("history"), s.counts["event"])
            row(L("ios_backup_settings_count"), s.settingsCount)
            row(L("ios_backup_prefs_files"), s.sharedFiles.count)
            row(L("ios_backup_covers"), s.covers)
            row(L("ios_backup_schema"), s.schemaVersion)
            textRow(L("ios_backup_accounts"), s.accounts.isEmpty ? L("ios_backup_none") : s.accounts.joined(separator: ", "))
            textRow(L("ios_backup_friends_key"), s.hasFriendsKey ? "✓" : L("ios_backup_none"))
        }
    }

    private func row(_ title: String, _ value: Int?) -> some View {
        textRow(title, value.map(String.init) ?? "—")
    }

    private func textRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func reload() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        found = files.filter { ["backup", "zip"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let backup = env.backup
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = backup.currentSummary()
            DispatchQueue.main.async { current = summary }
        }
    }

    private func restoreBackup(_ url: URL) {
        busy = .restoring
        let backup = env.backup
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try backup.restore(from: url) }
            // Копия из выбора файлов — временная, её убираем всегда; файл в папке приложения — только после успеха.
            let inAppFolder = url.standardizedFileURL.path.hasPrefix(docs)
            if case .success = result { try? FileManager.default.removeItem(at: url) }
            else if !inAppFolder { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async {
                if case .success = result { env.reloadAfterRestore() }
                busy = .none
                switch result {
                case .success(let summary):
                    restored = summary
                    var text = ""
                    if summary.schemaVersion > AppDatabase.schemaVersion {
                        text = L("ios_backup_newer_schema", summary.schemaVersion)
                    }
                    notice = Notice(title: L("ios_backup_restored"), text: text)
                case .failure(let error):
                    notice = Notice(title: L("restore_failed"), text: String(describing: error))
                }
                reload()
            }
        }
    }

    private func createBackup() {
        busy = .creating
        let backup = env.backup
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try backup.create() }
            DispatchQueue.main.async {
                busy = .none
                switch result {
                case .success(let url):
                    shared = SharedFile(url: url)
                case .failure(let error):
                    notice = Notice(title: L("backup_create_failed"), text: error.localizedDescription)
                }
            }
        }
    }
}
