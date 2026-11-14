import SwiftUI

/// «Импортировать плейлист»: список строк или ссылок → свой плейлист (Android `ImportPlaylistScreen`).
struct ImportPlaylistScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var importer = PlaylistImporter.shared
    @State private var name = ""
    @State private var text = ""
    @State private var preparing = false
    /// Красное поле: нажали «Импортировать» без названия, а взять его неоткуда (нет ссылки) — Android 2.3.0.
    @State private var nameError = false

    private var hasLink: Bool {
        text.components(separatedBy: .newlines).contains { PlaylistImporter.isPlaylistLink($0.trimmingCharacters(in: .whitespaces)) }
    }

    var body: some View {
        Form {
            if importer.running || importer.total > 0 {
                ImportProgressSection()
            }
            Section(footer: Text(L("import_links_supported") + "
" + L("import_no_download"))) {
                TextField(L("import_name"), text: $name)
                    .onChange(of: name) { _ in nameError = false }
                if nameError {
                    Text(L("import_name_required")).font(.caption).foregroundColor(.red)
                } else if name.trimmingCharacters(in: .whitespaces).isEmpty && hasLink {
                    Text(L("import_name_from_link")).font(.caption).foregroundColor(.secondary)
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("import_paste_placeholder")).foregroundColor(.secondary).padding(.top, 8).padding(.leading, 4)
                    }
                    TextEditor(text: $text).frame(minHeight: 160)
                }
                Button(action: start) {
                    HStack {
                        if preparing { ProgressView().padding(.trailing, 6) }
                        Text(L("import_start"))
                    }
                }
                .disabled(importer.running || preparing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                NavigationLink(destination: SoundCloudImportScreen()) {
                    Label(L("import_from_soundcloud"), systemImage: "cloud")
                }
            }
            Section(header: Text(L("import_help"))) {
                Text(L("import_help_body")).font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle(L("import_playlist"))
    }

    private func start() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty && !hasLink {
            nameError = true
            return
        }
        preparing = true
        let title = name.trimmingCharacters(in: .whitespaces)
        let pasted = text
        Task {
            let jobs = await PlaylistImporter.parse(pasted, name: title, existing: nil, env: env)
            await MainActor.run {
                preparing = false
                importer.run(jobs, env: env)
            }
        }
    }
}

/// Ход импорта: сколько найдено, что не нашлось, отмена.
struct ImportProgressSection: View {
    @ObservedObject private var importer = PlaylistImporter.shared

    var body: some View {
        Section {
            if importer.running {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(importer.current).lineLimit(1)
                        Text("\(importer.done) / \(importer.total)").font(.caption).foregroundColor(.secondary)
                    }
                }
                Button(L("import_cancel")) { importer.cancel() }.foregroundColor(.red)
            } else {
                Text(L("import_done", importer.found, importer.total))
                if importer.lastPlaylist != nil {
                    Text(L("ios_import_where")).font(.caption).foregroundColor(.secondary)
                }
            }
            if !importer.notFound.isEmpty {
                DisclosureGroup(L("import_not_found", importer.notFound.count)) {
                    ForEach(importer.notFound, id: \.self) { Text($0).font(.caption) }
                }
            }
        }
    }
}

/// Перенос профиля SoundCloud: лайки и плейлисты становятся своими плейлистами (Android `SoundCloudImportScreen`).
struct SoundCloudImportScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var importer = PlaylistImporter.shared
    @State private var link = ""
    @State private var loading = false
    @State private var failed = false
    @State private var profile: SoundCloudProvider.ImportProfile?
    @State private var picked = Set<String>()
    @State private var collecting = false

    private static let likesKey = "\u{1}likes"

    var body: some View {
        Form {
            if importer.running || importer.total > 0 {
                ImportProgressSection()
            }
            Section(footer: Text(L("soundcloud_import_hint"))) {
                TextField("soundcloud.com/…", text: $link)
                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                Button(action: find) {
                    HStack {
                        if loading { ProgressView().padding(.trailing, 6) }
                        Text(L("soundcloud_find"))
                    }
                }
                .disabled(loading || !link.contains("soundcloud.com/"))
                if failed { Text(L("soundcloud_not_found")).foregroundColor(.red).font(.caption) }
            }
            if let p = profile {
                Section(header: HStack(spacing: 10) {
                    ArtworkView(url: p.avatar, size: 32, circle: true, placeholderSymbol: "person.fill")
                    Text(p.name)
                }) {
                    if p.likes == 0 && p.sets.isEmpty { Text(L("soundcloud_nothing_public")).font(.caption) }
                    if p.likes > 0 {
                        pickRow(L("soundcloud_likes"), p.likes, L("soundcloud_likes_playlist", p.name), key: Self.likesKey)
                    }
                    ForEach(p.sets) { s in pickRow(s.title, s.trackCount, s.title, key: s.id) }
                }
                if p.likes > 0 || !p.sets.isEmpty {
                    Section(footer: Text(L("soundcloud_import_note"))) {
                        Button(action: start) {
                            HStack {
                                if collecting { ProgressView().padding(.trailing, 6) }
                                Text(L("soundcloud_import_start", picked.count))
                            }
                        }
                        .disabled(picked.isEmpty || importer.running || collecting)
                    }
                }
            }
        }
        .navigationTitle(L("soundcloud_import"))
    }

    private func existing(_ name: String) -> String? {
        env.library.playlists().first { $0.name == name && $0.isEditable }?.id
    }

    private func pickRow(_ title: String, _ count: Int, _ destination: String, key: String) -> some View {
        Button(action: { if picked.contains(key) { picked.remove(key) } else { picked.insert(key) } }) {
            HStack(spacing: 12) {
                Image(systemName: picked.contains(key) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(picked.contains(key) ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(LPlural("soundcloud_tracks", count) + " · " +
                         L(existing(destination) != nil ? "soundcloud_goes_existing" : "soundcloud_goes_new", destination))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func find() {
        guard let sc = env.player.audioEngine.soundCloud else { return }
        loading = true
        failed = false
        profile = nil
        let l = link
        Task {
            let p = await sc.importProfile(l)
            await MainActor.run {
                loading = false
                profile = p
                failed = p == nil
                if let p = p { picked = Set((p.likes > 0 ? [Self.likesKey] : []) + p.sets.map { $0.id }) }
            }
        }
    }

    private func start() {
        guard let p = profile, let sc = env.player.audioEngine.soundCloud else { return }
        collecting = true
        let keys = picked
        Task {
            var jobs: [PlaylistImporter.Job] = []
            if keys.contains(Self.likesKey) {
                let name = L("soundcloud_likes_playlist", p.name)
                jobs.append(PlaylistImporter.Job(name: name, existing: existing(name), items: await sc.importLikes(p.userId)))
            }
            for s in p.sets where keys.contains(s.id) {
                jobs.append(PlaylistImporter.Job(name: s.title, existing: existing(s.title), items: await sc.importSet(s.id)))
            }
            await MainActor.run {
                collecting = false
                importer.run(jobs, env: env)
            }
        }
    }
}
