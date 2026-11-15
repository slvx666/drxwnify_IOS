import SwiftUI

/// Чат с другом (SOC-1xx): сообщения, карточки музыки, ответ, правка, удаление, реакции, «печатает…», «прочитано».
struct ChatScreen: View {
    let peer: String
    @EnvironmentObject private var chats: ChatHub
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var player: PlayerController

    @State private var messages: [ChatMessage] = []
    @State private var lines: [ChatLine] = []
    @State private var reactions: [String: [ChatReaction]] = [:]
    /// Набранный текст — отдельный объект, на который подписано только поле ввода: раньше каждая буква
    /// перерисовывала весь чат, и на iPhone 8 клавиатура не успевала за пальцами.
    @State private var draft = ChatDraft()
    @State private var replyTo: ChatMessage?
    @State private var editing: ChatMessage?
    @StateObject private var keyboard = KeyboardWatcher()
    @State private var showStickers = false
    @State private var showMusic = false
    @State private var forwarding: ChatMessage?
    /// Меню сообщения поверх чата, как в Telegram: реакции сверху, сообщение, действия.
    @State private var menuFor: ChatMessage?
    @State private var allReactions = false
    @State private var reactionQuery = ""
    /// Насколько отлистано от низа (pt): кнопка «вниз» появляется дальше ~1,5 экрана.
    @State private var fromBottom: CGFloat = 0
    /// Низ ленты (несколько последних строк) на экране: пока виден — кнопки «вниз» нет.
    @State private var bottomVisible = true
    /// «Выбрать» (Android): выделенные сообщения; nil — обычный режим.
    @State private var selection: Set<String>?
    @State private var forwardingMany: [ChatMessage]?
    @EnvironmentObject private var env: AppEnvironment

    private static let quickReactions = ["❤️", "🔥", "😂", "👍", "😮", "😢"]

    private var name: String { friends.data[peer]?.name ?? friends.friends.first { $0.pubkey == peer }?.name ?? String(peer.prefix(8)) }

    var body: some View {
        let _ = RenderCount.hit("chat")
        VStack(spacing: 0) {
            // Лента перевёрнута: новое — у нижнего края сразу, без прокрутки при открытии (раньше чат пролистывался
            // сверху вниз за несколько кадров). Каждая строка переворачивается обратно.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        Color.clear.frame(height: 1).id("chat-bottom")
                        // Метка примерно в полэкрана от низа: ушла с экрана — показать «вниз».
                        Color.clear.frame(height: UIScreen.main.bounds.height * 0.5)
                            .onAppear { bottomVisible = true }
                            .onDisappear { bottomVisible = false }
                            .padding(.bottom, -UIScreen.main.bounds.height * 0.5)
                        if chats.isTyping(peer) {
                            Text(L("ios_typing")).font(.caption).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                                .flippedRow()
                        }
                        ForEach(lines.reversed()) { line in
                            Group {
                                if let day = line.day {
                                    Text(day).font(.caption.weight(.medium)).foregroundColor(.secondary)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                                        .padding(.vertical, 6)
                                } else if line.batch.count > 1 {
                                    batchBubble(line.batch)
                                } else if let m = line.batch.first {
                                    bubble(m)
                                }
                            }
                            // В режиме выбора строки отодвигаются вправо: кружок слева не налезает на сообщение.
                            .padding(.leading, selection != nil && line.day == nil ? 34 : 0)
                            .overlay(selectionOverlay(line))
                            .flippedRow()
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 10)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ChatOffsetKey.self, value: -g.frame(in: .named("chat")).minY)
                    })
                }
                .coordinateSpace(name: "chat")
                .flippedRow()
                .onPreferenceChange(ChatOffsetKey.self) { fromBottom = $0 }
                .overlay(scrollDownButton(proxy), alignment: .bottomTrailing)
            }
            if let sel = selection {
                selectionBar(sel)
            } else {
                inputBar
                    .padding(.bottom, miniPlayerGap)
            }
        }
        .overlay(menuOverlay)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabChrome()
        .background(EmptyView().sheet(item: $forwarding) { m in
            ForwardSheet(message: m, from: peer).environmentObject(friends).environmentObject(chats)
        })
        .background(EmptyView().sheet(isPresented: Binding(get: { forwardingMany != nil }, set: { if !$0 { forwardingMany = nil } })) {
            ForwardSheet(messages: forwardingMany ?? [], from: peer).environmentObject(friends).environmentObject(chats)
        })
        .onAppear {
            ChromeState.shared.chatOpen = true
            chats.openPeer = peer
            chats.hold("chat", true)
            reload()
            chats.markRead(peer)
        }
        .onDisappear {
            ChromeState.shared.chatOpen = false
            if chats.openPeer == peer { chats.openPeer = nil }
            chats.hold("chat", false)
        }
        .onChange(of: chats.revision) { _ in
            reload()
            chats.markRead(peer)
        }
    }

    // MARK: - Меню сообщения как в Telegram

    private func openMenu(_ m: ChatMessage) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        allReactions = false
        reactionQuery = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { menuFor = m }
    }

    private func closeMenu(then action: (() -> Void)? = nil) {
        withAnimation(.easeOut(duration: 0.18)) { menuFor = nil }
        if let a = action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: a) }
    }

    /// Затемнение и размытие чата, над сообщением — реакции (раскрываются в сетку с поиском), под ним — действия.
    @ViewBuilder private var menuOverlay: some View {
        if let m = menuFor {
            ZStack {
                BlurView(style: .systemUltraThinMaterialDark).opacity(0.9)
                    .overlay(Color.black.opacity(0.25))
                    .ignoresSafeArea()
                    .onTapGesture { closeMenu() }
                VStack(alignment: m.mine ? .trailing : .leading, spacing: 10) {
                    reactionPicker(m)
                    if !allReactions {
                        bubble(m).allowsHitTesting(false).padding(.horizontal, -10)
                        actionsCard(m)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
            }
            .transition(.opacity)
            .zIndex(10)
        }
    }

    private static let menuReactions = ["❤️", "👍", "🔥", "😂", "😢", "😮", "🤯"]

    @ViewBuilder private func reactionPicker(_ m: ChatMessage) -> some View {
        if allReactions {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(L("chat_reactions_search"), text: $reactionQuery).disableAutocorrection(true)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 6) {
                        ForEach(ReactionCatalog.search(reactionQuery), id: \.self) { e in
                            Button(action: { closeMenu { chats.react(m, key: e) } }) {
                                Text(e).font(.system(size: 30)).frame(height: 44)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .padding(12)
            .frame(width: min(340, UIMetrics.width - 28))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemBackground)))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            let mine = Set((reactions[m.id] ?? []).filter { $0.reactor == friends.profile?.pubkey }.flatMap { $0.keyList })
            HStack(spacing: 2) {
                ForEach(Self.menuReactions, id: \.self) { e in
                    Button(action: { closeMenu { chats.react(m, key: e) } }) {
                        Text(e).font(.system(size: 28)).frame(width: 40, height: 44)
                            .background(Circle().fill(mine.contains(e) ? Color.accentColor.opacity(0.3) : Color.clear))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Button(action: { withAnimation(.spring(response: 0.3)) { allReactions = true } }) {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).foregroundColor(.secondary)
                        .frame(width: 34, height: 34).background(Circle().fill(Color.secondary.opacity(0.2)))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 4)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
    }

    private func actionsCard(_ m: ChatMessage) -> some View {
        VStack(spacing: 0) {
            actionRow(L("ios_reply"), "arrowshape.turn.up.left") { replyTo = m; editing = nil }
            if !m.text.isEmpty || m.card != nil {
                actionRow(L("ios_copy"), "doc.on.doc") { UIPasteboard.general.string = m.text.isEmpty ? (m.card?.label ?? "") : Stickers.plain(m.text) }
            }
            actionRow(L("ios_forward"), "arrowshape.turn.up.right") { forwarding = m }
            actionRow(L("chat_select"), "checkmark.circle") { withAnimation(.easeOut(duration: 0.2)) { selection = [m.id] } }
            if m.mine && !m.text.isEmpty { actionRow(L("ios_edit"), "pencil") { editing = m; replyTo = nil; draft.text = m.text } }
            if m.mine && m.state == ChatMessage.stateFailed { actionRow(L("retry"), "arrow.clockwise") { chats.retry(m) } }
            if m.mine { actionRow(L("ios_delete_for_both"), "trash", destructive: true) { chats.delete(m, forBoth: true) } }
            actionRow(L("ios_delete_for_me"), "trash.slash", destructive: true) { chats.delete(m, forBoth: false) }
        }
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actionRow(_ title: String, _ symbol: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { closeMenu(then: action) }) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol).font(.system(size: 16))
            }
            .foregroundColor(destructive ? .red : .primary)
            .padding(.horizontal, 16).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .overlay(Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Выбор нескольких сообщений

    /// В режиме выбора вся строка — переключатель, слева кружок с галочкой.
    @ViewBuilder private func selectionOverlay(_ line: ChatLine) -> some View {
        if let sel = selection, line.day == nil {
            let ids = line.batch.map { $0.id }
            let on = ids.contains { sel.contains($0) }
            Button(action: {
                var s = sel
                if on { ids.forEach { s.remove($0) } } else { ids.forEach { s.insert($0) } }
                withAnimation(.easeOut(duration: 0.15)) { selection = s }
            }) {
                HStack {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22)).foregroundColor(on ? .accentColor : .secondary)
                        .padding(.leading, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func selectionBar(_ sel: Set<String>) -> some View {
        let chosen = messages.filter { sel.contains($0.id) }
        return HStack(spacing: 18) {
            Button(L("cancel")) { withAnimation(.easeOut(duration: 0.2)) { selection = nil } }
            Text(LPlural("n_selected", chosen.count)).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            Button(action: {
                UIPasteboard.general.string = chosen.map { $0.text.isEmpty ? ($0.card?.label ?? "") : Stickers.plain($0.text) }.joined(separator: "\n")
                selection = nil
            }) { Image(systemName: "doc.on.doc").frame(width: 36, height: 36) }
            .disabled(chosen.isEmpty)
            .accessibilityLabel(L("ios_copy"))
            Button(action: { forwardingMany = chosen; selection = nil }) {
                Image(systemName: "arrowshape.turn.up.right").frame(width: 36, height: 36)
            }
            .disabled(chosen.isEmpty)
            .accessibilityLabel(L("ios_forward"))
            Button(action: {
                chosen.forEach { chats.delete($0, forBoth: false) }
                selection = nil
            }) { Image(systemName: "trash").foregroundColor(.red).frame(width: 36, height: 36) }
            .disabled(chosen.isEmpty)
            .accessibilityLabel(L("ios_delete_for_me"))
        }
        .padding(.horizontal, 16).frame(height: 54)
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
    }

    /// «Вниз», как в Telegram: плавно появляется, когда отлистал вверх, и уходит у самого низа.
    private func scrollDownButton(_ proxy: ScrollViewProxy) -> some View {
        let show = !bottomVisible || fromBottom > UIScreen.main.bounds.height * 0.6
        return Button(action: { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("chat-bottom", anchor: .top) } }) {
            Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(BlurView(style: .systemThickMaterial).clipShape(Circle()))
                .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                .overlay(unreadBadge, alignment: .top)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.trailing, 14).padding(.bottom, 12)
        .opacity(show ? 1 : 0)
        .scaleEffect(show ? 1 : 0.6)
        .animation(.easeOut(duration: 0.2), value: show)
        .allowsHitTesting(show)
        .accessibilityLabel(L("ios_scroll_down"))
    }

    @ViewBuilder private var unreadBadge: some View {
        let n = chats.previews.first { $0.last.peer == peer }?.unread ?? 0
        if n > 0 {
            Text("\(n)").font(.caption2.weight(.bold)).foregroundColor(.white)
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color.accentColor)).offset(y: -9)
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
            .onLongPressGesture(minimumDuration: 0.35) { openMenu(m) }
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
            .onLongPressGesture(minimumDuration: 0.35) { openMenu(m) }
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
                            .onLongPressGesture(minimumDuration: 0.35) { openMenu(m) }
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
            Button(action: { editing = m; replyTo = nil; draft.text = m.text }) { Label(L("ios_edit"), systemImage: "pencil") }
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
                    // Крестик с зоной нажатия 44×44 (раньше по нему было трудно попасть).
                    Button(action: { replyTo = nil; if editing != nil { editing = nil; draft.text = "" } }) {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding(.horizontal, 12)
            }
            DraftSuggestions(draft: draft, editing: editing != nil) { s, n in useSuggestion(s, replacing: n) }
            HStack(spacing: 8) {
                Button(action: toggleStickers) {
                    Image(systemName: showStickers ? "keyboard" : "face.smiling").font(.system(size: 22)).frame(width: 34, height: 38)
                }
                .disabled(!chats.canWrite(peer))
                DraftField(draft: draft, placeholder: chats.canWrite(peer) ? L("ios_message") : L("ios_chat_readonly"),
                           canWrite: chats.canWrite(peer), editing: editing != nil,
                           onTyping: { chats.typingNow(peer) }, send: send, trackButton: currentTrackButton)
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

    /// Стикер из панели уходит сразу отдельным сообщением.
    private func sendSticker(_ s: StickerStore.Sticker) {
        chats.send(peer, text: StickerStore.token(s), replyTo: replyTo?.id)
        replyTo = nil
    }

    /// Подсказка заменяет набранный код; если кроме кода ничего нет — стикер уходит сразу.
    private func useSuggestion(_ s: StickerStore.Sticker, replacing n: Int) {
        let rest = String(draft.text.dropLast(n))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.text = ""
            sendSticker(s)
        } else {
            draft.text = rest + StickerStore.token(s)
        }
    }

    private func send() {
        let text = draft.text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let e = editing {
            chats.edit(e, newText: text)
            editing = nil
        } else {
            chats.send(peer, text: text, replyTo: replyTo?.id)
            replyTo = nil
        }
        draft.text = ""
    }

    // Форматтеры одни на все пузыри: раньше каждый пузырь при каждой перерисовке создавал новый.
    private static let todayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; return f }()

    private func time(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return (Calendar.current.isDateInToday(d) ? Self.todayFormat : Self.dayFormat).string(from: d)
    }
}

final class ChatDraft: ObservableObject {
    @Published var text = ""
}

/// Подсказки стикеров по набранному коду.
private struct DraftSuggestions: View {
    @ObservedObject var draft: ChatDraft
    let editing: Bool
    let use: (StickerStore.Sticker, Int) -> Void

    var body: some View {
        let list = editing || draft.text.isEmpty ? [] : StickerStore.suggest(draft.text)
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(list, id: \.0.id) { s, n in
                        StickerImage(id: s.id).stickerFrame(s.id, height: 52)
                            .onTapGesture { use(s, n) }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 58)
        }
    }
}

/// Поле ввода и кнопка «отправить» (или текущий трек, пока поле пустое).
private struct DraftField<TrackButton: View>: View {
    @ObservedObject var draft: ChatDraft
    let placeholder: String
    let canWrite: Bool
    let editing: Bool
    let onTyping: () -> Void
    let send: () -> Void
    let trackButton: TrackButton

    private var empty: Bool { draft.text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft.text)
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .disabled(!canWrite)
                .onChange(of: draft.text) { t in if !t.isEmpty && !editing { onTyping() } }
            if empty && !editing {
                trackButton
            } else {
                Button(action: send) {
                    Image(systemName: editing ? "checkmark.circle.fill" : "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(empty)
            }
        }
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

/// Сколько отлистано от низа перевёрнутой ленты.
private struct ChatOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Переворот по вертикали для ленты чата (без зеркала по горизонтали).
    func flippedRow() -> some View { scaleEffect(x: 1, y: -1, anchor: .center) }
}

/// Реакции для сетки (Android: «Поиск реакций»): эмодзи и слова для поиска.
enum ReactionCatalog {
    static let all: [(String, String)] = [
        ("❤️", "сердце любовь heart love"), ("👍", "лайк класс like thumbs up"), ("🔥", "огонь fire"), ("😂", "смех ржу laugh lol"),
        ("😭", "плачу cry"), ("😍", "влюблён love eyes"), ("🤯", "взрыв мозг mind blown"), ("👎", "дизлайк dislike"),
        ("😢", "грусть sad"), ("😮", "удивление wow"), ("😡", "злой angry"), ("🤔", "думаю think"),
        ("👏", "хлоп аплодисменты clap"), ("🎉", "праздник party"), ("💯", "сто 100"), ("🙏", "спасибо пожалуйста pray thanks"),
        ("👀", "глаза смотрю eyes"), ("😎", "круто cool"), ("🤣", "ору rofl"), ("😁", "улыбка grin"),
        ("🤗", "обнимаю hug"), ("🤝", "рукопожатие deal handshake"), ("💔", "разбитое сердце broken heart"), ("😱", "ужас scream"),
        ("🤮", "тошнит vomit"), ("🤡", "клоун clown"), ("💩", "какашка poop"), ("💀", "череп умер skull dead"),
        ("🙈", "не вижу monkey"), ("😴", "сплю sleep"), ("😈", "дьявол devil"), ("🤬", "мат ругаюсь swear"),
        ("🌚", "луна moon"), ("⚡", "молния lightning"), ("🏆", "кубок trophy"), ("🎵", "музыка нота music note"),
        ("🎸", "гитара guitar"), ("🥁", "барабан drum"), ("🎧", "наушники headphones"), ("🤘", "рок metal rock"),
        ("😇", "ангел angel"), ("🥰", "милота cute"), ("😏", "ухмылка smirk"), ("🙄", "закатил глаза eye roll"),
        ("😬", "неловко awkward"), ("🥶", "холодно cold"), ("🥵", "жарко hot"), ("✨", "блёстки sparkles"),
    ]

    static func search(_ q: String) -> [String] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { t.isEmpty || $0.1.contains(t) || $0.0 == t }.map { $0.0 }
    }
}
