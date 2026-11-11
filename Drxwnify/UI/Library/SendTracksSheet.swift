import SwiftUI

/// «Отправить» выбранные треки (Android 2.2.0, 2.2.5): в чат другу карточками музыки или ссылкой через «Поделиться».
struct SendTracksSheet: View {
    let tracks: [Track]
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.presentationMode) private var presentation
    @State private var shareItems: [Any]?
    @State private var sentTo: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(action: shareLinks) {
                        Label(L("ios_send_link"), systemImage: "link")
                    }
                }
                Section(header: Text(L("ios_send_to_chat"))) {
                    ForEach(env.friends.friends.filter { env.chats.canWrite($0.pubkey) }) { f in
                        Button(action: { send(to: f) }) {
                            HStack(spacing: 12) {
                                FriendAvatar(name: f.name, avatar: env.friends.data[f.pubkey]?.avatar, size: 36)
                                Text(env.friends.data[f.pubkey]?.name ?? f.name).foregroundColor(.primary)
                                Spacer()
                                if sentTo == f.pubkey { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(LPlural("n_song", tracks.count))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
    }

    private func shareLinks() {
        let lines = tracks.map { AppLinks.trackLink(mediaId: $0.id, title: $0.title, by: $0.artistNames) ?? "\($0.artistNames) — \($0.title)" }
        shareItems = [lines.joined(separator: "\n\n")]
    }

    private func send(to f: FriendsHub.Friend) {
        env.chats.send(f.pubkey, text: "", music: tracks.map { ChatMusic.of($0) })
        sentTo = f.pubkey
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { presentation.wrappedValue.dismiss() }
    }
}
