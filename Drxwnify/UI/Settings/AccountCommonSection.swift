import SwiftUI

/// Что есть у каждого привязанного музыкального аккаунта (Android 2.3.0 `AccountCommonSettings`):
/// основной ли он, вкладка в библиотеке (по умолчанию выключена), куда уходит лайк, перенос в основной, статистика.
struct AccountCommonSection: View {
    let source: CatalogSource
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var main = MainAccount.shared
    @ObservedObject private var remote = RemotePlaylists.shared
    @State private var onlyOne = false

    private var isMain: Bool { main.main == source }

    var body: some View {
        Group {
            Section(header: Text(L("account_section_main")),
                    footer: Text(isMain ? L("account_is_main_on") : (main.main.map { L("account_is_main_off", $0.title) } ?? ""))) {
                Toggle(isOn: Binding(get: { isMain }, set: { on in
                    if on {
                        main.choose(source)
                    } else if let other = main.linked.first(where: { $0 != source }) {
                        // Основным становится другой привязанный; если его нет — этот остаётся.
                        main.choose(other)
                    } else {
                        onlyOne = true
                    }
                })) {
                    Label(L("account_is_main"), systemImage: "star")
                }
                if !isMain {
                    Toggle(isOn: Binding(get: { main.tabShown(source) }, set: { main.setTab(source, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L("account_library_tab"), systemImage: "music.note.list")
                            Text(L("account_library_tab_desc")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Picker(selection: Binding(get: { main.likeMode }, set: { main.likeMode = $0 }),
                       label: Label(L("like_mode_title"), systemImage: "heart")) {
                    ForEach(MainAccount.LikeMode.allCases) { Text($0.title).tag($0) }
                }
            }
            if let m = main.main, !isMain {
                Section(header: Text(L("account_section_transfer"))) {
                    NavigationLink(destination: AccountTransferScreen(from: source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("transfer_from_to", source.title, m.title))
                            Text(L("transfer_from_desc")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            // Основной: импортированные в приложение плейлисты (файлы, ссылки) можно создать и в нём.
            if isMain, remote.localImportCount > 0 {
                Section(header: Text(L("account_section_transfer"))) {
                    Button(action: { remote.pushLocalImports(env: env) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("push_local_title", source.title)).foregroundColor(.primary)
                            Text(LPlural("push_local_desc", remote.localImportCount)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            if source == .SPOTIFY || source == .YANDEX {
                Section(header: Text(L("account_section_stats"))) {
                    NavigationLink(destination: ServiceStatsScreen(source: source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("service_stats_title"))
                            Text(L(source == .SPOTIFY ? "service_stats_desc_spotify" : "service_stats_desc_yandex")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .alert(isPresented: $onlyOne) { Alert(title: Text(L("account_only_one"))) }
    }
}
