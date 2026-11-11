import SwiftUI

/// Чат с другом (SOC-1xx): сообщения, карточки музыки, ответ, правка, удаление, реакции, «печатает…», «прочитано».
struct ChatScreen: View {
    let peer: String
    @EnvironmentObject private var chats: ChatHub
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var player: PlayerController

    @State private var messages: [ChatMessage] = []
    @State private var reactions: [String: [ChatReaction]] = [:]
    @State private var text = ""
    @State private var replyTo: ChatMessage?
    @State private var editing: ChatMessage?

    private static let quickReactions = ["❤️", "🔥", "😂", "👍", "😮", "😢"]

    private var name: String { friends.data[peer]?.name ?? friends.friends.first { $0.pubkey == peer }?.name ?? String(peer.prefix(8)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                        if chats.isTyping(peer) {
                            Text(L("ios_typing")).font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            inputBar
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing: currentTrackButton)
        .onAppear {
            chats.openPeer = peer
            chats.hold("chat", true)
            reload()
            chats.markRead(peer)
        }
        .onDisappear {
            if chats.openPeer == peer { chats.openPeer = nil }
            chats.hold("chat", false)
        }
        .onChange(of: chats.revision) { _ in
            reload()
            chats.markRead(peer)
        }
    }

    /// Отправить в чат то, что играет сейчас.
    private var currentTrackButton: some View {
        Button(action: {
            if let t = player.current { chats.send(peer, text: "", music: [ChatMusic.of(t)]) }
        }) {
            Image(systemName: "music.note.list")
        }
        .disabled(player.current == nil || !chats.canWrite(peer))
    }

    private func reload() {
        messages = chats.messages(peer)
        reactions = chats.reactions(peer)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.mine { Spacer(minLength: 50) }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 4) {
                if let r = m.replyTo, let original = messages.first(where: { $0.id == r }) {
                    Text(original.text.isEmpty ? (original.card?.label ?? "") : Stickers.plain(original.text))
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        .padding(.leading, 6)
                        .overlay(Rectangle().fill(Color.accentColor).frame(width: 2), alignment: .leading)
                }
                if let card = m.card { musicCard(card) }
                if !m.text.isEmpty { Text(Stickers.plain(m.text)).font(.body) }
                HStack(spacing: 4) {
                    if m.edited { Text(L("ios_edited")).font(.caption2) }
                    Text(time(m.ts)).font(.caption2)
                    if m.mine { stateIcon(m) }
                }
                .foregroundColor(.secondary)
                if let list = reactions[m.id], !list.isEmpty {
                    Text(list.flatMap { $0.keyList }.joined(separator: " ")).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(m.mine ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18)))
            .contextMenu { menu(m) }
            .onTapGesture(count: 2) { chats.react(m, key: "❤️") }
            if !m.mine { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private func menu(_ m: ChatMessage) -> some View {
        Button(action: { replyTo = m; editing = nil }) { Label(L("ios_reply"), systemImage: "arrowshape.turn.up.left") }
        ForEach(Self.quickReactions, id: \.self) { e in
            Button(action: { chats.react(m, key: e) }) { Text(e) }
        }
        if !m.text.isEmpty {
            Button(action: { UIPasteboard.general.string = Stickers.plain(m.text) }) { Label(L("ios_copy"), systemImage: "doc.on.doc") }
        }
        if m.mine && !m.text.isEmpty {
            Button(action: { editing = m; replyTo = nil; text = m.text }) { Label(L("ios_edit"), systemImage: "pencil") }
        }
        if m.mine && m.state == ChatMessage.stateFailed {
            Button(action: { chats.retry(m) }) { Label(L("retry"), systemImage: "arrow.clockwise") }
        }
        if m.mine {
            Button(action: { chats.delete(m, forBoth: true) }) { Label(L("ios_delete_for_both"), systemImage: "trash") }
        }
        Button(action: { chats.delete(m, forBoth: false) }) { Label(L("ios_delete_for_me"), systemImage: "trash.slash") }
    }

    @ViewBuilder private func stateIcon(_ m: ChatMessage) -> some View {
        switch m.state {
        case ChatMessage.stateSending: Image(systemName: "clock")
        case ChatMessage.stateFailed: Image(systemName: "exclamationmark.circle").foregroundColor(.red)
        default: Image(systemName: m.read ? "checkmark.circle.fill" : "checkmark")
        }
    }

    private func musicCard(_ c: ChatMusic) -> some View {
        Button(action: { open(c) }) {
            HStack(spacing: 10) {
                ArtworkView(url: c.cover, size: 48, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(c.by).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Image(systemName: c.kind == .track ? "play.circle.fill" : "chevron.right").foregroundColor(.accentColor)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @EnvironmentObject private var env: AppEnvironment

    private func open(_ c: ChatMusic) {
        if let t = c.track {
            player.play([t], title: name)
        } else if !c.isYouTube {
            env.linkTarget = AppLinks.Target(kind: c.kind, id: c.id, title: c.title, by: c.by)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let r = replyTo ?? editing {
                HStack {
                    Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left").foregroundColor(.accentColor)
                    Text(r.text.isEmpty ? (r.card?.label ?? "") : Stickers.plain(r.text)).font(.caption).lineLimit(1)
                    Spacer()
                    Button(action: { replyTo = nil; if editing != nil { editing = nil; text = "" } }) { Image(systemName: "xmark") }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(chats.canWrite(peer) ? L("ios_message") : L("ios_chat_readonly"), text: $text)
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .disabled(!chats.canWrite(peer))
                    .onChange(of: text) { t in if !t.isEmpty && editing == nil { chats.typingNow(peer) } }
                Button(action: send) {
                    Image(systemName: editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
    }

    private func send() {
        if let e = editing {
            chats.edit(e, newText: text)
            editing = nil
        } else {
            chats.send(peer, text: text, replyTo: replyTo?.id)
            replyTo = nil
        }
        text = ""
    }

    private func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM HH:mm"
        return f.string(from: d)
    }
}
