import SwiftUI

/// Чат с другом (SOC-1xx): сообщения, карточки музыки, ответ, правка, удаление, реакции, «печатает…», «прочитано».
struct ChatScreen: View {
    let peer: String
    @EnvironmentObject private var chats: ChatHub
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var player: PlayerController

    @State private var messages: [ChatMessage] = []
    @State private var lines: [ChatLine] = []
    @State private var acting: ChatMessage?
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
                        ForEach(lines) { line in
                            if let day = line.day {
                                Text(day).font(.caption.weight(.medium)).foregroundColor(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                                    .padding(.vertical, 6)
                            } else if line.batch.count > 1 {
                                batchBubble(line.batch).id(line.id)
                            } else if let m = line.batch.first {
                                bubble(m).id(m.id)
                            }
                        }
                        if chats.isTyping(peer) {
                            Text(L("ios_typing")).font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onAppear { if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: messages.count) { _ in
                    if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            inputBar
                .padding(.bottom, miniPlayerGap)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .background(EmptyView().sheet(item: $acting) { m in
            MessageActionsSheet(message: m, mine: m.mine, quick: Self.quickReactions,
                                react: { chats.react(m, key: $0) },
                                reply: { replyTo = m; editing = nil },
                                copy: { UIPasteboard.general.string = m.text.isEmpty ? (m.card?.label ?? "") : Stickers.plain(m.text) },
                                forward: { forwarding = m },
                                edit: m.mine && !m.text.isEmpty ? { editing = m; replyTo = nil; text = m.text } : nil,
                                retry: m.mine && m.state == ChatMessage.stateFailed ? { chats.retry(m) } : nil,
                                deleteForBoth: m.mine ? { chats.delete(m, forBoth: true) } : nil,
                                deleteForMe: { chats.delete(m, forBoth: false) })
                .modifier(MediumSheet())
        })
        .background(EmptyView().sheet(item: $forwarding) { m in
            ForwardSheet(message: m, from: peer).environmentObject(friends).environmentObject(chats)
        })
        .onAppear {
            env.chatOpen = true
            chats.openPeer = peer
            chats.hold("chat", true)
            reload()
            chats.markRead(peer)
        }
        .onDisappear {
            env.chatOpen = false
            if chats.openPeer == peer { chats.openPeer = nil }
            chats.hold("chat", false)
        }
        .onChange(of: chats.revision) { _ in
            reload()
            chats.markRead(peer)
        }
    }

    /// В чате мини-плеера нет (сообщил пользователь): строка ввода стоит у нижнего края.
    private var miniPlayerGap: CGFloat { 0 }

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
        lines = ChatLine.build(messages)
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
            .onTapGesture(count: 2) { chats.react(m, key: MessagesSettingsScreen.quick(env.prefs.shared("chat"))) }
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                acting = m
            }
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
            .onTapGesture(count: 2) { chats.react(m, key: MessagesSettingsScreen.quick(env.prefs.shared("chat"))) }
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                acting = m
            }
            .modifier(SwipeToReply { replyTo = m; editing = nil })
            if !m.mine { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 10)
    }

    /// Треки, отправленные вместе, — одним пузырём (как на Android и в Telegram).
    private func batchBubble(_ batch: [ChatMessage]) -> some View {
        let first = batch[0], last = batch[batch.count - 1]
        return HStack {
            if first.mine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(batch) { m in
                    if let c = m.card {
                        musicCard(c)
                            .onLongPressGesture(minimumDuration: 0.35) { acting = m }
                    }
                }
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(time(last.ts)).font(.caption2)
                    if last.mine { stateIcon(last) }
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: UIMetrics.width * 0.78, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(first.mine ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18)))
            .modifier(SwipeToReply { replyTo = last; editing = nil })
            if !first.mine { Spacer(minLength: 50) }
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
                Button(action: toggleStickers) {
                    Image(systemName: showStickers ? "keyboard" : "face.smiling").font(.system(size: 22)).frame(width: 34, height: 38)
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
            if showStickers {
                Divider()
                StickerPanel { s in sendSticker(s) }
                    .frame(height: UIMetrics.isShort ? 230 : 290)
                    .transition(.move(edge: .bottom))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, showStickers ? 0 : 8)
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
        .onChange(of: keyboard.visible) { v in if v && showStickers { withAnimation(.easeOut(duration: 0.2)) { showStickers = false } } }
    }

    /// ☺ ↔ клавиатура: панель стикеров встаёт на место клавиатуры.
    private func toggleStickers() {
        if showStickers {
            withAnimation(.easeOut(duration: 0.2)) { showStickers = false }
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation(.easeOut(duration: 0.25)) { showStickers = true }
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
