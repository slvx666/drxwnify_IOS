import SwiftUI

/// Временные экраны вкладок (этап 0). Каждый заменяется на своём этапе.
struct StagePlaceholder: View {
    let systemImage: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(L("stage_placeholder"))
                .font(.headline)
            Text(note)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .miniPlayerInset()
    }
}

struct HomeScreen: View {
    var body: some View {
        StagePlaceholder(systemImage: "house", note: appVersionLine)
            .navigationTitle(L("home"))
    }

    private var appVersionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Drxwnify \(version) (\(build)) · iOS \(UIDevice.current.systemVersion)"
    }
}

struct SearchScreen: View {
    var body: some View {
        StagePlaceholder(systemImage: "magnifyingglass", note: "")
            .navigationTitle(L("search"))
    }
}

struct TogetherScreen: View {
    var body: some View {
        StagePlaceholder(systemImage: "person.2", note: "")
            .navigationTitle(L("together"))
    }
}

struct LibraryScreen: View {
    var body: some View {
        StagePlaceholder(systemImage: "music.note.list", note: "")
            .navigationTitle(L("filter_library"))
    }
}
