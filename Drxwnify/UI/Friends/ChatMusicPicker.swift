import SwiftUI

/// Панель музыки в чате (Android 2.2.1): то, что играет, недавние, любимые и поиск; можно отметить несколько
/// треков и отправить их карточками разом.
struct ChatMusicPicker: View {
    let send: ([Track]) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation

    private enum Tab: Int, CaseIterable { case recent, liked, search }

    @State private var tab = Tab.recent
    @State private var recent: [Track] = []
    @State private var liked: [Track] = []
    @State private var query = ""
    @State private var found: [Track] = []
    @State private var searching = false
    @State private var picked: [Track] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L("ios_recent")).tag(Tab.recent)
                    Text(L("liked")).tag(Tab.liked)
                    Text(L("search")).tag(Tab.search)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16).padding(.vertical, 8)
                if tab == .search {
                    TextField(L("search"), text: $query)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .padding(.horizontal, 16).padding(.bottom, 6)
                        .onChange(of: query) { _ in runSearch() }
                }
                List {
                    if let t = player.current, tab == .recent {
                        Section(header: Text(L("now_playing"))) { row(t) }
                    }
                    Section {
                        ForEach(list, id: \.id) { row($0) }
                        if searching { ProgressView().frame(maxWidth: .infinity) }
                    }
                }
                .listStyle(PlainListStyle())
            }
            .navigationTitle(L("ios_chat_music"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(L("close")) { presentation.wrappedValue.dismiss() },
                trailing: Button(picked.isEmpty ? L("ios_send") : "\(L("ios_send")) (\(picked.count))") {
                    send(picked)
                    presentation.wrappedValue.dismiss()
                }
                .disabled(picked.isEmpty))
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: loadLocal)
    }

    private var list: [Track] {
        switch tab {
        case .recent: return recent
        case .liked: return liked
        case .search: return found
        }
    }

    private func row(_ t: Track) -> some View {
        let on = picked.contains { $0.id == t.id }
        return Button(action: {
            if let i = picked.firstIndex(where: { $0.id == t.id }) { picked.remove(at: i) } else { picked.append(t) }
        }) {
            HStack(spacing: 12) {
                ArtworkView(url: t.artworkUrl, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).foregroundColor(.primary).lineLimit(1)
                    Text(t.artistNames).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundColor(on ? .accentColor : .secondary)
            }
        }
    }

    private func loadLocal() {
        let lib = env.library
        DispatchQueue.global(qos: .userInitiated).async {
            var seen = Set<String>()
            let r = lib.history(limit: 200).map { $0.track }.filter { seen.insert($0.id).inserted }
            let l = lib.likedSongs()
            DispatchQueue.main.async {
                recent = Array(r.prefix(60))
                liked = l
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { found = []; searching = false; return }
        let api = env.spotify
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let r = try? await api.search(q, limit: 20)
            if Task.isCancelled { return }
            await MainActor.run {
                found = (r?.tracks ?? []).map { Track($0) }
                searching = false
            }
        }
    }
}
