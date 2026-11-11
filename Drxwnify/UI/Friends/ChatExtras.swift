import SwiftUI

/// Ответ свайпом по сообщению вправо (Android 2.2.2): пузырь едет за пальцем, со стрелкой; дальше 60 pt — ответ.
struct SwipeToReply: ViewModifier {
    let reply: () -> Void
    @State private var dx: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .overlay(Image(systemName: "arrowshape.turn.up.left.fill").foregroundColor(.accentColor)
                        .opacity(Double(min(1, dx / 60))).offset(x: -24 + dx / 3), alignment: .leading)
            .gesture(DragGesture(minimumDistance: 25).onChanged { g in
                guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                dx = max(0, min(90, g.translation.width))
            }.onEnded { _ in
                if dx > 60 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    reply()
                }
                withAnimation(.spring()) { dx = 0 }
            })
    }
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
