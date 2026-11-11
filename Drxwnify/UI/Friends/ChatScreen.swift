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
    @StateObject private var keyboard = KeyboardWatcher()
    @State private var showStickers = false
    @State private var showMusic = false
    @State private var forwarding: ChatMessage?
    @EnvironmentObject private var env: AppEnvironment

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
                .padding(.bottom, miniPlayerGap)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .background(EmptyView().sheet(item: $forwarding) { m in
            ForwardSheet(message: m, from: peer).environmentObject(friends).environmentObject(chats)
        })
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

    /// Как на Android: строка ввода стоит над мини-плеером; с клавиатурой мини-плеер уходит под неё.
    private var miniPlayerGap: CGFloat {
        if #available(iOS 26.0, *) { return 0 }
        return player.current != nil && !keyboard.visible ? MiniPlayerView.classicHeight + 4 : 0
    }

    /// Музыка в чат (значок ♪ справа, как на Android): панель с тем, что играет, недавними, любимыми и поиском.
    private var currentTrackButton: some View {
        Button(action: { showMusic = true }) {
            Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).frame(width: 36, height: 38)
        }
        .disabled(!chats.canWrite(peer))
        .sheet(isPresented: $showMusic) {
            ChatMusicPicker { tracks in
                if !tracks.isEmpty { chats.send(peer, text: "", music: tracks.map { ChatMusic.of($0) }) }
            }
            .environmentObject(env)
            .environmentObject(player)
        }
    }

    private func reload() {
        messages = chats.messages(peer)
        reactions = chats.reactions(peer)
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.card == nil, m.replyTo == nil, let ids = StickerStore.stickerOnly(m.text) {
            stickerBubble(m, ids: ids)
        } else {
            textBubble(m)
        }
    }

    /// Только стикеры: крупно, без пузыря (как на Android).
    private func stickerBubble(_ m: ChatMessage, ids: [String]) -> some View {
        HStack {
            if m.mine { Spacer(minLength: 50) }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                        StickerImage(id: id).stickerFrame(id, height: ids.count == 1 ? 130 : 96)
                    }
                }
                HStack(spacing: 4) {
                    Text(time(m.ts)).font(.caption2)
                    if m.mine { stateIcon(m) }
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                if let list = reactions[m.id], !list.isEmpty {
                    Text(list.flatMap { $0.keyList }.joined(separator: " ")).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            .contentShape(Rectangle())
            .contextMenu { menu(m) }
            .onTapGesture(count: 2) { chats.react(m, key: "❤️") }
            .modifier(SwipeToReply { replyTo = m; editing = nil })
            if !m.mine { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 10)
    }

    /// Текст сообщения со стикерами на своих местах.
    @ViewBuilder private func messageText(_ text: String) -> some View {
        let parts = StickerStore.parts(text)
        if parts.count == 1, case .text(let t) = parts[0] {
            Text(t).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    switch p {
                    case .text(let t): Text(t).font(.body)
                    case .image(let id): StickerImage(id: id).stickerFrame(id, height: 48)
                    }
                }
            }
        }
    }

    private func textBubble(_ m: ChatMessage) -> some View {
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
                if !m.text.isEmpty { messageText(m.text) }
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
            .modifier(SwipeToReply { replyTo = m; editing = nil })
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
        Button(action: { forwarding = m }) { Label(L("ios_forward"), systemImage: "arrowshape.turn.up.right") }
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


    private func open(_ c: ChatMusic) {
        if let t = c.track {
            // Как на Android 2.2.5: дальше играют следующие треки чата.
            let all = messages.compactMap { $0.card?.track }
            let start = all.firstIndex { $0.id == t.id } ?? 0
            player.play(all.isEmpty ? [t] : all, startIndex: all.isEmpty ? 0 : start, title: name)
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
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestions, id: \.0.id) { s, n in
                            StickerImage(id: s.id).stickerFrame(s.id, height: 52)
                                .onTapGesture { useSuggestion(s, replacing: n) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 58)
            }
            HStack(spacing: 8) {
                Button(action: { showStickers = true }) {
                    Image(systemName: "face.smiling").font(.system(size: 24)).frame(width: 34, height: 38)
                }
                .disabled(!chats.canWrite(peer))
                TextField(chats.canWrite(peer) ? L("ios_message") : L("ios_chat_readonly"), text: $text)
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .disabled(!chats.canWrite(peer))
                    .onChange(of: text) { t in if !t.isEmpty && editing == nil { chats.typingNow(peer) } }
                if text.trimmingCharacters(in: .whitespaces).isEmpty && editing == nil {
                    currentTrackButton
                } else {
                    Button(action: send) {
                        Image(systemName: editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
        .sheet(isPresented: $showStickers) {
            StickerPanel { s in sendSticker(s) }
        }
    }

    private var suggestions: [(StickerStore.Sticker, Int)] {
        editing == nil && !text.isEmpty ? StickerStore.suggest(text) : []
    }

    /// Стикер из панели уходит сразу отдельным сообщением.
    private func sendSticker(_ s: StickerStore.Sticker) {
        chats.send(peer, text: StickerStore.token(s), replyTo: replyTo?.id)
        replyTo = nil
    }

    /// Подсказка заменяет набранный код; если кроме кода ничего нет — стикер уходит сразу.
    private func useSuggestion(_ s: StickerStore.Sticker, replacing n: Int) {
        let rest = String(text.dropLast(n))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            text = ""
            sendSticker(s)
        } else {
            text = rest + StickerStore.token(s)
        }
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

/// Видна ли клавиатура (iOS 14 без `keyboardLayoutGuide` в SwiftUI).
final class KeyboardWatcher: ObservableObject {
    @Published private(set) var visible = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        let c = NotificationCenter.default
        tokens.append(c.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in self?.visible = true })
        tokens.append(c.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in self?.visible = false })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
