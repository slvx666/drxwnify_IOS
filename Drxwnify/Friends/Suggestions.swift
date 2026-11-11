import Foundation

/// Предложка (CRITICAL §1.5, `friends/Suggestions.kt`): идея, баг или ненаходящийся трек — разработчику зашифрованным
/// личным сообщением Nostr (kind 4, NIP-04) через те же релеи, без сервера. Подписывается ключом профиля «Друзей»,
/// если он есть, иначе отдельным анонимным ключом. Ответы разработчика (`drxw-reply`) ищутся 25 с после запуска
/// и показываются на весь экран по одному.
final class Suggestions: ObservableObject {
    enum Topic: String, CaseIterable { case idea, bug, track, other }

    struct Reply: Identifiable, Hashable { var id: String; var text: String; var quote: String?; var at: Int64 }

    static let shared = Suggestions()
    private static let kindDM = 4
    private static let type = "drxw-suggest"
    private static let replyType = "drxw-reply"
    private static let maxText = 2000
    private static let maxPerHour = 5
    private static let inboxDays: Int64 = 180
    private static let replyListen: TimeInterval = 25

    @Published private(set) var replies: [Reply] = []
    private let defaults = UserDefaults(suiteName: "suggestions") ?? .standard
    weak var friends: FriendsHub?

    private var sentTimes: [Int64] {
        (defaults.string(forKey: "sent") ?? "").split(separator: ",").compactMap { Int64($0) }
    }

    /// За последний час отправлено слишком много (застрявшая кнопка не должна завалить разработчика).
    var limited: Bool {
        let hourAgo = FriendsHub.nowMs() - 3_600_000
        return sentTimes.filter { $0 > hourAgo }.count >= Self.maxPerHour
    }

    private func anonymousKey() -> [UInt8] {
        if let hex = defaults.string(forKey: "anonKey"), let k = [UInt8](hexString: hex) { return k }
        let sk = Secp256k1.newPrivateKey()
        defaults.set(sk.hex, forKey: "anonKey")
        return sk
    }

    /// Отправляет; `false` — ничего не ушло (пусто или лимит за час).
    @discardableResult
    func send(_ topic: Topic, _ text: String) -> Bool {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxText))
        guard !body.isEmpty, !limited else { return false }
        let key = friends?.secretKey ?? anonymousKey()
        var payload: JSONObject = ["t": Self.type, "topic": topic.rawValue, "text": body,
                                   "v": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"]
        if let name = friends?.profile?.name, !name.isEmpty { payload["name"] = name }
        guard let content = Nostr.encrypt(privateKey: key, to: FriendsHub.developerPubkey, plain: JSON.string(payload)) else { return false }
        RelayPool.shared.publish(Nostr.sign(privateKey: key, kind: Self.kindDM, tags: [["p", FriendsHub.developerPubkey]], content: content))
        let hourAgo = FriendsHub.nowMs() - 3_600_000
        let recent = sentTimes.filter { $0 > hourAgo } + [FriendsHub.nowMs()]
        defaults.set(recent.map(String.init).joined(separator: ","), forKey: "sent")
        return true
    }

    /// Ищет ответы разработчика на предложения с этого телефона (на ключ профиля и на анонимный) 25 с после запуска.
    func checkReplies() {
        var keys: [[UInt8]] = []
        if let k = friends?.secretKey { keys.append(k) }
        if let hex = defaults.string(forKey: "anonKey"), let k = [UInt8](hexString: hex), !keys.contains(k) { keys.append(k) }
        keys = keys.filter { Secp256k1.publicKey($0).hex != FriendsHub.developerPubkey }
        guard !keys.isEmpty else { return }
        let since = FriendsHub.nowMs() / 1000 - Self.inboxDays * 86400
        let subs: [String] = keys.map { sk in
            let filter: JSONObject = ["kinds": [Self.kindDM], "authors": [FriendsHub.developerPubkey],
                                      "#p": [Secp256k1.publicKey(sk).hex], "since": since]
            return RelayPool.shared.subscribe([filter]) { [weak self] event in
                guard let self = self, event.pubkey == FriendsHub.developerPubkey,
                      let plain = Nostr.decrypt(privateKey: sk, from: event.pubkey, payload: event.content),
                      let o = JSON.object(plain), o.str("t") == Self.replyType, let text = o.str("text"), !text.isEmpty else { return }
                let reply = Reply(id: event.id, text: text, quote: o.str("q").flatMap { $0.isEmpty ? nil : $0 }, at: event.createdAt * 1000)
                DispatchQueue.main.async {
                    let seen = Set(self.defaults.stringArray(forKey: "seenReplies") ?? [])
                    guard !seen.contains(reply.id), !self.replies.contains(where: { $0.id == reply.id }) else { return }
                    self.replies = (self.replies + [reply]).sorted { $0.at < $1.at }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyListen) {
            subs.forEach { RelayPool.shared.close($0) }
        }
    }

    func markSeen(_ id: String) {
        defaults.set((defaults.stringArray(forKey: "seenReplies") ?? []) + [id], forKey: "seenReplies")
        replies.removeAll { $0.id == id }
    }
}
