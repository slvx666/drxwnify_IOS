import SwiftUI

/// Страница друга: что слушает сейчас («слушать вместе»), история, плейлисты, лайки, статистика; чат.
struct FriendScreen: View {
    let pubkey: String
    /// «Как меня видят»: показать эти данные вместо полученных, без чата и удаления.
    var previewData: FriendsHub.FriendData? = nil
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation
    @State private var confirmRemove = false

    private var data: FriendsHub.FriendData? { previewData ?? friends.data[pubkey] }
    private var name: String { data?.name ?? friends.friends.first { $0.pubkey == pubkey }?.name ?? String(pubkey.prefix(8)) }

    var body: some View {
        List {
            VStack(spacing: 8) {
                FriendAvatar(name: name, avatar: data?.avatar, size: UIMetrics.scaled(96))
                Text(name).font(.title3.weight(.bold))
                if previewData == nil {
                NavigationLink(destination: ChatScreen(peer: pubkey)) {
                    Label(L("ios_chat"), systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            if let now = data?.now {
                Section(header: Text(L(now.playing ? "ios_friend_now" : "ios_friend_paused"))) {
                    refRow(now.track, context: [now.track])
                    if now.listenAlong {
                        if friends.listeningTo == pubkey {
                            Button(action: friends.stopListenAlong) { Label(L("ios_listen_along_stop"), systemImage: "stop.circle") }
                        } else {
                            Button(action: { friends.startListenAlong(pubkey) }) { Label(L("ios_listen_along"), systemImage: "headphones") }
                        }
                    }
                }
            }
            if let s = data?.stats {
                Section(header: Text(L("stats"))) {
                    HStack {
                        statCell("\(s.weekMinutes)", L("ios_stats_minutes"))
                        statCell("\(s.weekPlays)", L("ios_stats_plays"))
                        statCell("\(s.likedCount)", L("liked"))
                    }
                    ForEach(Array(s.topArtists.enumerated()), id: \.offset) { i, a in
                        HStack {
                            Text("\(i + 1).").foregroundColor(.secondary).frame(width: 24, alignment: .leading)
                            Text(a.0)
                            Spacer()
                            Text("\(a.1)").foregroundColor(.secondary)
                        }
                    }
                }
            }
            if let history = data?.history, !history.isEmpty {
                Section(header: Text(L("history"))) {
                    ForEach(Array(history.prefix(20).enumerated()), id: \.offset) { _, r in refRow(r, context: history) }
                }
            }
            if let likes = data?.likes, !likes.tracks.isEmpty {
                Section(header: Text(L("liked") + " · \(likes.total)")) {
                    NavigationLink(destination: RefListScreen(title: L("liked"), refs: likes.tracks)) {
                        Label(LPlural("n_song", likes.tracks.count), systemImage: "heart.fill")
                    }
                }
            }
            if let playlists = data?.playlists, !playlists.isEmpty {
                Section(header: Text(L("playlists"))) {
                    ForEach(Array(playlists.enumerated()), id: \.offset) { _, p in
                        NavigationLink(destination: RefListScreen(title: p.name, refs: p.tracks)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(LPlural("n_song", p.total)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            if pubkey != FriendsHub.developerPubkey || friends.friends.contains(where: { $0.pubkey == pubkey }) {
                Section {
                    Button(action: { friends.togglePinned(pubkey) }) {
                        Label(L(friends.pinned.contains(pubkey) ? "ios_unpin" : "ios_pin"), systemImage: "pin")
                    }
                    Button(action: { confirmRemove = true }) {
                        Label(L("ios_friends_remove"), systemImage: "person.badge.minus").foregroundColor(.red)
                    }
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $confirmRemove) {
            Alert(title: Text(L("ios_friends_remove_confirm", name)),
                  primaryButton: .destructive(Text(L("ios_friends_remove"))) {
                      friends.removeFriend(pubkey)
                      presentation.wrappedValue.dismiss()
                  },
                  secondaryButton: .cancel(Text(L("cancel"))))
        }
        .onAppear { friends.startLive() }
        .onDisappear { friends.stopLive() }
    }

    private func statCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold))
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func refRow(_ r: FriendsHub.TrackRef, context: [FriendsHub.TrackRef]) -> some View {
        TrackRow(track: r.track, context: context.map { $0.track }, index: context.firstIndex(of: r) ?? 0, queueTitle: name)
    }
}

/// Список треков друга (плейлист, лайки).
struct RefListScreen: View {
    let title: String
    let refs: [FriendsHub.TrackRef]

    var body: some View {
        let tracks = refs.map { $0.track }
        List {
            TrackPlayShuffleRow(tracks: tracks, queueTitle: title)
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, context: tracks, index: i, queueTitle: title)
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(PlainListStyle())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// «Как меня видят другие» (Android 1.5.1): свой профиль глазами друга, отмеченного друга или любого человека.
struct ProfilePreviewScreen: View {
    @EnvironmentObject private var friends: FriendsHub
    @State private var viewer = 2

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewer) {
                Text(L("ios_audience_friends")).tag(2)
                Text(L("ios_audience_verified")).tag(1)
                Text(L("ios_audience_everyone")).tag(3)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, 16).padding(.vertical, 8)
            FriendScreen(pubkey: friends.profile?.pubkey ?? "", previewData: friends.preview(minRank: viewer))
                .id(viewer)
        }
        .navigationTitle(L("ios_how_others_see"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
