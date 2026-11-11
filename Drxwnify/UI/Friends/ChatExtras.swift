import SwiftUI

/// Ответ свайпом по сообщению вправо (Android 2.2.2): пузырь едет за пальцем, со стрелкой; дальше 60 pt — ответ.
struct SwipeToReply: ViewModifier {
    let reply: () -> Void
    @State private var dx: CGFloat = 0

    /// Свайп влево, как на Android: стрелка «ответить» выезжает справа.
    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .overlay(Image(systemName: "arrowshape.turn.up.left.fill").foregroundColor(.accentColor)
                        .opacity(Double(min(1, -dx / 60))).offset(x: 24 + dx / 3), alignment: .trailing)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { g in
                guard abs(g.translation.width) > abs(g.translation.height) * 1.6 else { return }
                dx = min(0, max(-90, g.translation.width))
            }.onEnded { _ in
                if dx < -60 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    reply()
                }
                withAnimation(.spring()) { dx = 0 }
            })
    }
}

/// Строка чата: день или сообщение (несколько треков подряд — одним пузырём).
struct ChatLine: Identifiable {
    let id: String
    var day: String?
    var batch: [ChatMessage] = []

    /// Треки без текста, отправленные одним человеком с разницей ≤ 3 с, — вместе (`BATCH_GAP_MS` на Android).
    static func build(_ messages: [ChatMessage]) -> [ChatLine] {
        var out: [ChatLine] = []
        var lastDay = ""
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguage.current)
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        func lone(_ m: ChatMessage) -> Bool { m.text.trimmingCharacters(in: .whitespaces).isEmpty && m.replyTo == nil && m.card?.kind == .track }
        var i = 0
        while i < messages.count {
            let m = messages[i]
            let date = Date(timeIntervalSince1970: Double(m.ts) / 1000)
            let day = Calendar.current.isDateInToday(date) ? L("today") : f.string(from: date)
            if day != lastDay {
                out.append(ChatLine(id: "day-" + day + "-\(m.ts)", day: day))
                lastDay = day
            }
            var j = i + 1
            if lone(m) {
                while j < messages.count, lone(messages[j]), messages[j].mine == m.mine, messages[j].ts - messages[j - 1].ts <= 3000 { j += 1 }
            }
            let batch = Array(messages[i..<j])
            out.append(ChatLine(id: batch.count > 1 ? "batch-" + m.id : m.id, batch: batch))
            i = j
        }
        return out
    }
}

/// Меню сообщения по долгому нажатию (как на Android): реакции в ряд, дальше действия.
struct MessageActionsSheet: View {
    let message: ChatMessage
    let mine: Bool
    let quick: [String]
    let react: (String) -> Void
    let reply: () -> Void
    let copy: () -> Void
    let forward: () -> Void
    var edit: (() -> Void)?
    var retry: (() -> Void)?
    var deleteForBoth: (() -> Void)?
    let deleteForMe: () -> Void
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 36, height: 4).padding(.top, 8)
                Text(message.text.isEmpty ? (message.card?.label ?? "") : Stickers.plain(message.text))
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                HStack(spacing: 0) {
                    ForEach(quick, id: \.self) { e in
                        Button(action: { react(e); close() }) {
                            Text(e).font(.system(size: 30)).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
                VStack(spacing: 2) {
                    row(L("ios_reply"), "arrowshape.turn.up.left", reply)
                    row(L("ios_copy"), "doc.on.doc", copy)
                    row(L("ios_forward"), "arrowshape.turn.up.right", forward)
                    if let e = edit { row(L("ios_edit"), "pencil", e) }
                    if let r = retry { row(L("retry"), "arrow.clockwise", r) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(spacing: 2) {
                    if let d = deleteForBoth { row(L("ios_delete_for_both"), "trash", d, destructive: true) }
                    row(L("ios_delete_for_me"), "trash.slash", deleteForMe, destructive: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: {
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
        }) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 26)
                Text(title)
                Spacer(minLength: 0)
            }
            .foregroundColor(destructive ? .red : .primary)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func close() { presentation.wrappedValue.dismiss() }
}

/// Переслать сообщение другому другу (Android 2.2.1): текст и карточка музыки уходят как есть.
struct ForwardSheet: View {
    let message: ChatMessage
    let from: String
    @EnvironmentObject private var friends: FriendsHub
    @EnvironmentObject private var chats: ChatHub
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            List {
                ForEach(friends.friends.filter { $0.pubkey != from && chats.canWrite($0.pubkey) }) { f in
                    Button(action: { forward(to: f.pubkey) }) {
                        HStack(spacing: 12) {
                            FriendAvatar(name: f.name, avatar: friends.data[f.pubkey]?.avatar, size: 36)
                            Text(friends.data[f.pubkey]?.name ?? f.name).foregroundColor(.primary)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("ios_forward"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func forward(to peer: String) {
        chats.send(peer, text: message.text, music: message.card.map { [$0] } ?? [])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        presentation.wrappedValue.dismiss()
    }
}
