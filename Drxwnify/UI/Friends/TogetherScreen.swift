import SwiftUI

/// Вкладка «Вместе»: профиль, запросы в друзья, друзья с тем, что они слушают, и чаты (SOC-0xx, SOC-1xx).
struct TogetherScreen: View {
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var chats: ChatHub

    var body: some View {
        Group {
            if friends.hasProfile {
                FriendsListView()
            } else {
                CreateProfileView()
            }
        }
        .navigationTitle(L("together"))
        .onAppear {
            friends.startLive()
            chats.hold("screen", true)
            ChatNotifier.requestPermission()
        }
        .onDisappear {
            friends.stopLive()
            chats.hold("screen", false)
        }
    }
}

/// Аватар друга: base64-JPEG или первая буква имени.
struct FriendAvatar: View {
    let name: String
    let avatar: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let a = avatar, let data = Data(base64Encoded: a), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.accentColor.opacity(0.35)
                    Text(String(name.first ?? "?").uppercased()).font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct CreateProfileView: View {
    @EnvironmentObject private var friends: FriendsHub
    @State private var name = ""
    @State private var nsec = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section(header: Text(L("ios_friends_create")), footer: Text(L("ios_friends_create_hint"))) {
                TextField(L("ios_friends_name"), text: $name)
                Button(L("ios_friends_create_action")) { friends.createProfile(name: name) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section(header: Text(L("ios_friends_restore")), footer: Text(error ?? L("ios_friends_restore_hint")).foregroundColor(error == nil ? .secondary : .red)) {
                SecureField("nsec1…", text: $nsec)
                Button(L("ios_friends_restore_action")) {
                    if !friends.importProfile(nsec: nsec, name: name) { error = L("ios_friends_bad_key") }
                }
                .disabled(nsec.isEmpty)
            }
        }
    }
}

private struct FriendsListView: View {
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var chats: ChatHub
    @State private var showAdd = false
    @State private var shareItems: [Any]?

    private var sortedFriends: [FriendsHub.Friend] {
        friends.friends.sorted { a, b in
            let pa = friends.pinned.contains(a.pubkey), pb = friends.pinned.contains(b.pubkey)
            if pa != pb { return pa }
            let na = friends.data[a.pubkey]?.now?.playing == true, nb = friends.data[b.pubkey]?.now?.playing == true
            if na != nb { return na }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    var body: some View {
        List {
            if let me = friends.profile {
                Section {
                    NavigationLink(destination: MyProfileScreen()) {
                        HStack(spacing: 12) {
                            FriendAvatar(name: me.name, avatar: me.avatar, size: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.name.isEmpty ? L("ios_friends_no_name") : me.name).font(.headline)
                                Text(L("ios_friends_my_profile")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Button(action: { if let link = friends.inviteLink() { shareItems = [link] } }) {
                        Label(L("ios_friends_invite"), systemImage: "person.badge.plus")
                    }
                }
            }
            if !friends.requests.isEmpty {
                Section(header: Text(L("ios_friends_requests"))) {
                    ForEach(friends.requests) { r in
                        HStack {
                            FriendAvatar(name: r.name, avatar: friends.data[r.pubkey]?.avatar, size: 40)
                            Text(r.name.isEmpty ? String(r.pubkey.prefix(8)) : r.name)
                            Spacer()
                            Button(action: { friends.addFriend(r.pubkey, name: r.name) }) {
                                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(.green)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            Button(action: { friends.dismissRequest(r.pubkey) }) {
                                Image(systemName: "xmark.circle").font(.title2).foregroundColor(.secondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
            }
            if !chats.previews.isEmpty {
                Section(header: Text(L("ios_chats"))) {
                    ForEach(chats.previews) { p in
                        NavigationLink(destination: ChatScreen(peer: p.last.peer)) {
                            ChatPreviewRow(preview: p)
                        }
                    }
                }
            }
            Section(header: HStack {
                Text(L("ios_friends"))
                Spacer()
                Button(action: { showAdd = true }) { Image(systemName: "plus") }
            }) {
                ForEach(sortedFriends) { f in
                    NavigationLink(destination: FriendScreen(pubkey: f.pubkey)) { FriendRow(friend: f) }
                }
                if friends.friends.isEmpty {
                    Text(L("ios_friends_empty")).foregroundColor(.secondary)
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }
        .listStyle(InsetGroupedListStyle())
        .sheet(isPresented: $showAdd) { AddFriendSheet().environmentObject(friends) }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
    }
}

private struct FriendRow: View {
    let friend: FriendsHub.Friend
    @EnvironmentObject private var friends: FriendsHub

    var body: some View {
        let d = friends.data[friend.pubkey]
        HStack(spacing: 12) {
            FriendAvatar(name: d?.name ?? friend.name, avatar: d?.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(d?.name ?? friend.name).lineLimit(1)
                    if friend.pubkey == FriendsHub.developerPubkey {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundColor(.accentColor)
                    }
                    if friends.pinned.contains(friend.pubkey) { Image(systemName: "pin.fill").font(.caption2).foregroundColor(.secondary) }
                }
                if let now = d?.now {
                    HStack(spacing: 4) {
                        Image(systemName: now.playing ? "waveform" : "pause.fill").font(.caption2)
                            .foregroundColor(now.playing ? .green : .secondary)
                        Text("\(now.track.artist) — \(now.track.title)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct ChatPreviewRow: View {
    let preview: ChatPreview
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var chats: ChatHub

    var body: some View {
        let peer = preview.last.peer
        let d = friends.data[peer]
        let name = d?.name ?? friends.friends.first { $0.pubkey == peer }?.name ?? String(peer.prefix(8))
        HStack(spacing: 12) {
            FriendAvatar(name: name, avatar: d?.avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(chats.isTyping(peer) ? L("ios_typing") : previewText)
                    .font(.caption).foregroundColor(chats.isTyping(peer) ? .accentColor : .secondary).lineLimit(1)
            }
            Spacer()
            if preview.unread > 0 {
                Text("\(preview.unread)").font(.caption2.weight(.bold)).foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.accentColor))
            }
        }
    }

    private var previewText: String {
        let m = preview.last
        let body = m.text.isEmpty ? (m.card.map { "♪ " + $0.label } ?? "") : Stickers.plain(m.text)
        return (m.mine ? L("ios_you") + ": " : "") + body
    }
}

/// Добавить друга: код (npub), ссылка-приглашение или поиск по нику.
private struct AddFriendSheet: View {
    @EnvironmentObject private var friends: FriendsHub
    @Environment(\.presentationMode) private var presentation
    @State private var code = ""
    @State private var query = ""
    @State private var found: [FriendsHub.Found] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("ios_friends_by_code")), footer: Text(error ?? L("ios_friends_by_code_hint")).foregroundColor(error == nil ? .secondary : .red)) {
                    TextField("npub1… / https://drxwnify.pages.dev/add/…", text: $code).autocapitalization(.none).disableAutocorrection(true)
                    Button(L("ios_friends_add")) {
                        if let pub = friends.parseCode(code) {
                            friends.addFriend(pub)
                            presentation.wrappedValue.dismiss()
                        } else {
                            error = L("ios_friends_bad_code")
                        }
                    }
                    .disabled(code.isEmpty)
                    Button(L("ios_paste")) { code = UIPasteboard.general.string ?? "" }
                }
                Section(header: Text(L("ios_friends_by_name"))) {
                    HStack {
                        TextField(L("ios_friends_name"), text: $query, onCommit: search)
                        if searching { ProgressView() } else { Button(L("search"), action: search).disabled(query.count < 2) }
                    }
                    ForEach(found) { f in
                        HStack {
                            FriendAvatar(name: f.name, avatar: f.avatar, size: 36)
                            Text(f.name)
                            Spacer()
                            if friends.friends.contains(where: { $0.pubkey == f.pubkey }) {
                                Image(systemName: "checkmark").foregroundColor(.secondary)
                            } else {
                                Button(L("ios_friends_add")) { friends.addFriend(f.pubkey, name: f.name) }.buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("ios_friends_add"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func search() {
        guard query.count >= 2 else { return }
        searching = true
        friends.searchByName(query) { list in
            found = list
            searching = false
        }
    }
}

/// Свой профиль: имя, код, приватность, резервный ключ.
struct MyProfileScreen: View {
    @EnvironmentObject private var friends: FriendsHub
    @State private var name = ""
    @State private var showKey = false
    @State private var shareItems: [Any]?

    private func audienceTitle(_ a: FriendsHub.Audience) -> String {
        switch a {
        case .NOBODY: return L("ios_audience_nobody")
        case .VERIFIED: return L("ios_audience_verified")
        case .FRIENDS: return L("ios_audience_friends")
        case .EVERYONE: return L("ios_audience_everyone")
        }
    }

    private func audiencePicker(_ title: String, _ keyPath: WritableKeyPath<FriendsHub.Privacy, FriendsHub.Audience>) -> some View {
        Picker(title, selection: Binding(get: { friends.privacy[keyPath: keyPath] }, set: {
            var p = friends.privacy
            p[keyPath: keyPath] = $0
            friends.setPrivacy(p)
        })) {
            ForEach(FriendsHub.Audience.allCases, id: \.self) { Text(audienceTitle($0)).tag($0) }
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<FriendsHub.Privacy, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { friends.privacy[keyPath: keyPath] }, set: {
            var p = friends.privacy
            p[keyPath: keyPath] = $0
            friends.setPrivacy(p)
        }))
    }

    var body: some View {
        Form {
            if let me = friends.profile {
                Section {
                    HStack {
                        FriendAvatar(name: me.name, avatar: me.avatar, size: 64)
                        TextField(L("ios_friends_name"), text: $name, onCommit: { friends.rename(name) })
                            .font(.title3.weight(.semibold))
                    }
                    Button(action: { if let link = friends.inviteLink() { shareItems = [link] } }) {
                        Label(L("ios_friends_invite"), systemImage: "square.and.arrow.up")
                    }
                    Button(action: { UIPasteboard.general.string = me.code }) {
                        Label(L("ios_friends_copy_code"), systemImage: "doc.on.doc")
                    }
                    Text(me.code).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Section(header: Text(L("ios_privacy"))) {
                audiencePicker(L("ios_privacy_now"), \.nowPlaying)
                audiencePicker(L("ios_privacy_history"), \.history)
                audiencePicker(L("ios_privacy_playlists"), \.playlists)
                audiencePicker(L("ios_privacy_stats"), \.stats)
                toggle(L("ios_privacy_discoverable"), \.discoverable)
                toggle(L("ios_privacy_along"), \.listenAlong)
                toggle(L("ios_privacy_read"), \.readReceipts)
            }
            Section(footer: Text(L("ios_friends_key_hint"))) {
                Button(L("ios_friends_show_key")) { showKey.toggle() }
                if showKey, let key = friends.backupKey() {
                    Text(key).font(.system(.caption, design: .monospaced))
                    Button(L("ios_friends_copy_key")) { UIPasteboard.general.string = key }
                }
            }
        }
        .navigationTitle(L("ios_friends_my_profile"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = friends.profile?.name ?? "" }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
    }
}
