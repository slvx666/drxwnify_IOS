import SwiftUI

/// Корень настроек. Полный набор экранов — этап 13.
struct SettingsScreen: View {
    var body: some View {
        List {
            NavigationLink(destination: BackupScreen()) {
                Label(L("backup_restore"), systemImage: "externaldrive")
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("settings"))
        .miniPlayerInset()
    }
}
