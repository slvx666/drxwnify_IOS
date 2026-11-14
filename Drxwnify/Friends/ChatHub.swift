import Foundation
import Combine
import GRDB
import UIKit
import UserNotifications

struct ChatMessage: Identifiable, Hashable {
    static let stateSending = 0, stateSent = 1, stateFailed = 2, stateReceived = 3

    var owner: String
    var peer: String
    var id: String
    var mine: Bool
    var ts: Int64
    var text: String
    var music: String?
    var replyTo: String?
    var state = ChatMessage.stateReceived
    var read = false
    var edited = false
    var deleted = false
    var event: String?
    var eventId: String?

    init(owner: String, peer: String, id: String, mine: Bool, ts: Int64, text: String, music: String? = nil, replyTo: String? = nil,
         state: Int = ChatMessage.stateReceived, read: Bool = false, edited: Bool = false, deleted: Bool = false,
         event: String? = nil, eventId: String? = nil) {
        self.owner = owner; self.peer = peer; self.id = id; self.mine = mine; self.ts = ts; self.text = text
        self.music = music; self.replyTo = replyTo; self.state = state; self.read = read; self.edited = edited
        self.deleted = deleted; self.event = event; self.eventId = eventId
    }

    init(row r: Row) {
        self.init(owner: r["owner"], peer: r["peer"], id: r["id"], mine: (r["mine"] as Int) != 0, ts: r["ts"], text: r["text"],
                  music: r["music"], replyTo: r["replyTo"], state: r["state"], read: (r["read"] as Int) != 0,
                  edited: (r["edited"] as Int) != 0, deleted: (r["deleted"] as Int) != 0, event: r["event"], eventId: r["eventId"])
    }

    var card: ChatMusic? { ChatMusic(json: music) }
}

struct ChatReaction: Hashable {
    var owner: String
    var peer: String
    var msgId: String
    var reactor: String
    var keys: String
    var ts: Int64
    var state: Int
    var event: String?

    var keyList: [String] { keys.components(separatedBy: "\n").filter { !$0.isEmpty } }
}

struct ChatPreview: Identifiable, Hashable {
    var last: ChatMessage
    var unread: Int
    var id: String { last.peer }
}

/// Музыкальная карточка в чате (`friends/ChatMusic.kt`): `{"k","id","t","a","i"?,"d"?,"n"?}`.
struct ChatMusic: Hashable {
    var kind: AppLinks.Kind
    var id: String
    var title: String
    var by: String
    var cover: String?
    var durationMs: Int64 = 0
    var count = 0

    var isYouTube: Bool { id.hasPrefix(AppLinks.youtubePrefix) }

    var json: JSONObject {
        var o: JSONObject = ["k": kind.rawValue, "id": id, "t": title, "a": by]
        if let c = cover { o["i"] = c }
        if durationMs > 0 { o["d"] = durationMs }
        if count > 0 { o["n"] = count }
        return o
    }

    init(kind: AppLinks.Kind, id: String, title: String, by: String, cover: String? = nil, durationMs: Int64 = 0, count: Int = 0) {
        self.kind = kind; self.id = id; self.title = title; self.by = by; self.cover = cover; self.durationMs = durationMs; self.count = count
    }

    init?(object o: JSONObject) {
        guard let k = o.str("k").flatMap(AppLinks.Kind.init(rawValue:)), let id = o.str("id") else { return nil }
        let cover = o.str("i")
        self.init(kind: k, id: id, title: o.str("t") ?? "", by: o.str("a") ?? "", cover: (cover?.hasPrefix("http") ?? false) ? cover : nil,
                  durationMs: Int64(o.int("d") ?? 0), count: o.int("n") ?? 0)
    }

    init?(json text: String?) {
        guard let t = text, let o = JSON.object(t) else { return nil }
        self.init(object: o)
    }

    var label: String { by.isEmpty ? title : "\(by) — \(title)" }

    /// Трек для плеера.
    var track: Track? {
        guard kind == .track else { return nil }
        let catalog = isYouTube ? nil : id
        return Track(id: catalog.map(FallbackIds.of) ?? String(id.dropFirst(AppLinks.youtubePrefix.count)), catalogId: catalog, title: title,
                     artists: by.components(separatedBy: ", ").filter { !$0.isEmpty }.map { Track.Artist(id: nil, name: $0) },
                     albumId: nil, albumName: nil, durationMs: Int(durationMs), artworkUrl: cover)
    }

    static func of(_ t: Track) -> ChatMusic {
        ChatMusic(kind: .track, id: t.catalogId ?? (AppLinks.youtubePrefix + t.id), title: t.title, by: t.artistNames,
                  cover: t.artworkUrl, durationMs: Int64(t.durationMs))
    }
}

/// Чаты с друзьями — перенос `friends/ChatHub.kt` (CRITICAL §1.4). База — `chat.db` с той же схемой, что Room v2 на Android.
final class ChatHub: ObservableObject {
    static let protocolVersion = 2
    static let protocolReactions = 2

    private static let type = "drxw-chat"
    private static let typeReact = "drxw-react"
    private static let kindDM = 4
    private static let kindDelete = 5
    private static let kindTyping = 21004
    private static let kMsg = "msg", kEdit = "edit", kDel = "del", kRead = "read", kTyping = "typing"
    private static let maxText = 4000
    private static let reactDebounce: TimeInterval = 1.2
    private static let firstLookS: Int64 = 30 * 24 * 3600
    private static let overlapS: Int64 = 10 * 60
    private static let sendTimeout: TimeInterval = 20
    private static let typingEvery: TimeInterval = 4
    static let typingShown: TimeInterval = 6
    private static let releaseAfter: TimeInterval = 180

    struct PeerStatus: Equatable {
        var addedMe: Bool
        var proto: Int
        var version: String?
        var hasChat: Bool { proto > 0 }
    }

    /// Меняется при каждой записи в базу: экраны перечитывают.
    @Published private(set) var revision = 0
    @Published private(set) var previews: [ChatPreview] = []
    @Published private(set) var unreadTotal = 0
    @Published private(set) var typing: [String: Date] = [:]
    @Published private(set) var peers: [String: PeerStatus] = [:]
    /// Открытый сейчас чат (входящие в нём сразу прочитаны).
    var openPeer: String?

    private let friends: FriendsHub
    private let store: TypedStore
    private let relays = RelayPool.shared
    private let db: DatabaseQueue?
    private var holders = Set<String>()
    private var liveSub: String?
    private var liveKeys: Set<String>?
    private var releaseWork: DispatchWorkItem?
    private var delivering = Set<String>()
    private var lastSentTs: Int64 = 0
    private var reactionWork: [String: DispatchWorkItem] = [:]
    private var lastTypingSent: [String: Date] = [:]

    init(friends: FriendsHub, prefs: Prefs) {
        self.friends = friends
        store = prefs.shared("chat")
        db = Self.openDatabase()
        peers = loadPeers()
        friends.onFriendsChanged = { [weak self] in self?.friendsChanged() }
        relays.onOpen = { [weak self] in self?.retrySoon() }
        refresh()
        if friends.hasProfile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.retryOutbox() }
        }
    }

    private static func openDatabase() -> DatabaseQueue? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let q = try? DatabaseQueue(path: dir.appendingPathComponent("chat.db").path) else { return nil }
        try? q.write { d in
            try d.execute(sql: """
                CREATE TABLE IF NOT EXISTS `message` (`owner` TEXT NOT NULL, `peer` TEXT NOT NULL, `id` TEXT NOT NULL, `mine` INTEGER NOT NULL, `ts` INTEGER NOT NULL, `text` TEXT NOT NULL, `music` TEXT, `replyTo` TEXT, `state` INTEGER NOT NULL, `read` INTEGER NOT NULL, `edited` INTEGER NOT NULL, `deleted` INTEGER NOT NULL, `event` TEXT, `eventId` TEXT, PRIMARY KEY(`owner`, `peer`, `id`));
                CREATE INDEX IF NOT EXISTS `index_message_owner_peer_ts` ON `message` (`owner`, `peer`, `ts`);
                CREATE TABLE IF NOT EXISTS `reaction` (`owner` TEXT NOT NULL, `peer` TEXT NOT NULL, `msgId` TEXT NOT NULL, `reactor` TEXT NOT NULL, `keys` TEXT NOT NULL, `ts` INTEGER NOT NULL, `state` INTEGER NOT NULL, `event` TEXT, PRIMARY KEY(`owner`, `peer`, `msgId`, `reactor`));
                CREATE INDEX IF NOT EXISTS `index_reaction_owner_peer` ON `reaction` (`owner`, `peer`);
                CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT);
                INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, '4d286124da611d86411e99ff57ea5f53');
                PRAGMA user_version = 2;
                """)
        }
        return q
    }

    private var me: String? { friends.profile?.pubkey }

    func canWrite(_ peer: String) -> Bool {
        peer == FriendsHub.developerPubkey || friends.profile?.isDeveloper == true || friends.friends.contains { $0.pubkey == peer }
    }

    // MARK: - Чтение

    private func changed() {
        DispatchQueue.main.async {
            self.revision += 1
            self.refresh()
        }
    }

    func refresh() {
        guard let me = me, let db = db else {
            previews = []
            unreadTotal = 0
            return
        }
        previews = (try? db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT m.*, (SELECT COUNT(*) FROM message u WHERE u.owner = m.owner AND u.peer = m.peer
                             AND u.mine = 0 AND u.read = 0 AND u.deleted = 0) AS unread
                FROM message m
                WHERE m.owner = ? AND m.deleted = 0 AND m.ts = (
                    SELECT MAX(x.ts) FROM message x WHERE x.owner = m.owner AND x.peer = m.peer AND x.deleted = 0)
                GROUP BY m.peer ORDER BY m.ts DESC
                """, arguments: [me]).map { ChatPreview(last: ChatMessage(row: $0), unread: $0["unread"]) }
        }) ?? []
        unreadTotal = previews.reduce(0) { $0 + $1.unread }
        UIApplication.shared.applicationIconBadgeNumber = unreadTotal
    }

    func messages(_ peer: String) -> [ChatMessage] {
        guard let me = me, let db = db else { return [] }
        return (try? db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM message WHERE owner = ? AND peer = ? AND deleted = 0 ORDER BY ts ASC, id ASC",
                             arguments: [me, peer]).map(ChatMessage.init(row:))
        }) ?? []
    }

    func reactions(_ peer: String) -> [String: [ChatReaction]] {
        guard let me = me, let db = db else { return [:] }
        let list: [ChatReaction] = (try? db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM reaction WHERE owner = ? AND peer = ?", arguments: [me, peer]).map {
                ChatReaction(owner: $0["owner"], peer: $0["peer"], msgId: $0["msgId"], reactor: $0["reactor"], keys: $0["keys"],
                             ts: $0["ts"], state: $0["state"], event: $0["event"])
            }
        }) ?? []
        return Dictionary(grouping: list.filter { !$0.keyList.isEmpty }, by: { $0.msgId })
    }

    func markRead(_ peer: String) {
        guard let me = me, let db = db else { return }
        let newest = (try? db.read { try Int64.fetchOne($0, sql: "SELECT MAX(ts) FROM message WHERE owner = ? AND peer = ? AND mine = 0 AND read = 0", arguments: [me, peer]) }) ?? nil
        guard let upTo = newest else { return }
        try? db.write { try $0.execute(sql: "UPDATE message SET read = 1 WHERE owner = ? AND peer = ? AND mine = 0", arguments: [me, peer]) }
        changed()
        sendRead(peer, upTo: upTo)
    }

    // MARK: - Подключение

    /// Держать входящие на связи (экран чатов открыт, играет музыка).
    func hold(_ reason: String, _ on: Bool) {
        let changedSet = on ? holders.insert(reason).inserted : (holders.remove(reason) != nil)
        guard changedSet else { return }
        if !holders.isEmpty {
            releaseWork?.cancel()
            releaseWork = nil
            openLive()
        } else {
            releaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.holders.isEmpty else { return }
                self.closeLive()
            }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseAfter, execute: work)
        }
    }

    private func senders() -> Set<String>? {
        if friends.profile?.isDeveloper == true { return nil }
        return Set(friends.friends.map { $0.pubkey } + [FriendsHub.developerPubkey])
    }

    private func inboxFilter(_ me: String, since: Int64) -> JSONObject {
        var f: JSONObject = ["kinds": [Self.kindDM, Self.kindTyping], "#p": [me], "since": since]
        if let s = senders() { f["authors"] = Array(s) }
        return f
    }

    /// Откуда смотреть: курсор минус 10 минут; в первый раз — 30 дней назад.
    private func since() -> Int64 {
        let cursor = Int64(store.value("cursor_\(me ?? "")").flatMap(Int.fromPref) ?? 0)
        let now = Int64(Date().timeIntervalSince1970)
        return cursor == 0 ? now - Self.firstLookS : min(cursor, now) - Self.overlapS
    }

    private func advanceCursor(_ createdAt: Int64) {
        let key = "cursor_\(me ?? "")"
        let now = Int64(Date().timeIntervalSince1970)
        let cur = Int64(store.value(key).flatMap(Int.fromPref) ?? 0)
        if createdAt > cur && createdAt <= now + 60 { store.setLong(Int(createdAt), for: key) }
    }

    private func openLive() {
        guard let me = me else { return }
        let keys = senders() ?? []
        if liveSub != nil && liveKeys == keys { return }
        closeLive()
        liveKeys = keys
        liveSub = relays.subscribe([inboxFilter(me, since: since())]) { [weak self] in self?.onEvent($0) }
        retryOutbox()
        syncHistoryOnce()
    }

    // MARK: - История с релеев (после восстановления копии)

    /// Переписка живёт в базе телефона, в резервную копию она не входит, а курсор `cursor_<ключ>` из копии Android свежий —
    /// поэтому на новом телефоне с тем же ключом прошлые сообщения не приходили, а свои отправленные — никогда
    /// (подписка просит только адресованные мне). Один раз на этом телефоне для этого ключа: входящие от друзей и свои
    /// исходящие к ним за год, сколько релеи ещё хранят. Свои расшифровываются тем же общим секретом (ECDH симметричен).
    private static let historyS: Int64 = 365 * 24 * 3600

    private func syncHistoryOnce() {
        guard let me = me else { return }
        let flag = "chat_history_synced_" + me
        if UserDefaults.standard.bool(forKey: flag) { return }
        UserDefaults.standard.set(true, forKey: flag)
        let since = Int64(Date().timeIntervalSince1970) - Self.historyS
        var incoming: JSONObject = ["kinds": [Self.kindDM], "#p": [me], "since": since]
        if let s = senders() { incoming["authors"] = Array(s) }
        var outgoing: JSONObject = ["kinds": [Self.kindDM], "authors": [me], "since": since]
        if let s = senders() { outgoing["#p"] = Array(s) }
        var subId = ""
        var ends = 0
        subId = relays.subscribe([incoming, outgoing], onEose: { [weak self] in
            ends += 1
            if ends >= 3 { self?.relays.close(subId) }
        }) { [weak self] e in
            guard let self = self else { return }
            if e.pubkey == me { self.onOwnEvent(e) } else { self.onEvent(e, history: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.relays.close(subId) }
    }

    /// Своё сообщение, отправленное с другого телефона (Android) тем же ключом.
    private func onOwnEvent(_ event: NostrEvent) {
        guard let me = me, let sk = friends.secretKey, event.pubkey == me, let peer = event.tag("p"), peer != me,
              let plain = Nostr.decrypt(privateKey: sk, from: peer, payload: event.content),
              let o = JSON.object(plain), o.str("t") == Self.type,
              let id = o.str("id"), !id.isEmpty, id.count <= 64 else { return }
        let ts: Int64 = {
            if let v = o.int("ts"), v > 0 { return min(Int64(v), event.createdAt * 1000 + 60_000) }
            return event.createdAt * 1000
        }()
        let text = String((o.str("text") ?? "").prefix(Self.maxText))
        switch o.str("k") {
        case Self.kMsg:
            let music = o.obj("m").flatMap(ChatMusic.init(object:)).map { JSON.string($0.json) }
            _ = insert(ChatMessage(owner: me, peer: peer, id: id, mine: true, ts: ts, text: text, music: music,
                                   replyTo: o.str("re").flatMap { $0.isEmpty ? nil : $0 }, state: ChatMessage.stateSent, read: true))
        case Self.kEdit:
            if var old = get(me, peer, id), old.mine, !old.deleted {
                old.text = text
                old.edited = true
                update(old)
            }
        case Self.kDel:
            if var old = get(me, peer, id), old.mine {
                old.text = ""
                old.music = nil
                old.deleted = true
                update(old)
            }
        default:
            return
        }
        changed()
    }

    private func closeLive() {
        if let s = liveSub { relays.close(s) }
        liveSub = nil
        liveKeys = nil
    }

    func friendsChanged() {
        if liveSub != nil { openLive() }
    }

    /// Один взгляд на новые сообщения без постоянной связи (фоновая проверка): до двух EOSE или 15 с.
    func checkOnce(completion: @escaping () -> Void) {
        guard let me = me, liveSub == nil else { return completion() }
        var ends = 0
        var finished = false
        var subId = ""
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.relays.close(subId)
                completion()
            }
        }
        subId = relays.subscribe([inboxFilter(me, since: since())], onEose: {
            ends += 1
            if ends >= 2 { finish() }
        }) { [weak self] in self?.onEvent($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish() }
    }

    // MARK: - Приём

    /// `history`: старое сообщение из разовой подгрузки — без уведомления, уже прочитано (его читали на другом телефоне).
    private func onEvent(_ event: NostrEvent, history: Bool = false) {
        guard let me = me, let sk = friends.secretKey else { return }
        let author = event.pubkey
        guard author != me, event.tag("p") == me,
              let plain = Nostr.decrypt(privateKey: sk, from: author, payload: event.content),
              let o = JSON.object(plain) else { return }
        let t = o.str("t")
        guard t == Self.type || t == Self.typeReact else { return }
        notePeer(author, proto: o.int("v") ?? 0)
        if t == Self.typeReact {
            applyReaction(me: me, author: author, event: event, o: o)
            advanceCursor(event.createdAt)
            return
        }
        if event.kind == Self.kindTyping {
            if o.str("k") == Self.kTyping { typing[author] = Date().addingTimeInterval(Self.typingShown) }
            return
        }
        apply(me: me, author: author, event: event, o: o, history: history)
        if !history { advanceCursor(event.createdAt) }
    }

    private func insert(_ m: ChatMessage) -> Bool {
        guard let db = db else { return false }
        return ((try? db.write { d -> Bool in
            try d.execute(sql: """
                INSERT OR IGNORE INTO message (owner, peer, id, mine, ts, text, music, replyTo, state, read, edited, deleted, event, eventId)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [m.owner, m.peer, m.id, m.mine ? 1 : 0, m.ts, m.text, m.music, m.replyTo, m.state, m.read ? 1 : 0,
                                 m.edited ? 1 : 0, m.deleted ? 1 : 0, m.event, m.eventId])
            return d.changesCount > 0
        }) ?? false)
    }

    private func update(_ m: ChatMessage) {
        try? db?.write { d in
            try d.execute(sql: """
                UPDATE message SET mine = ?, ts = ?, text = ?, music = ?, replyTo = ?, state = ?, read = ?, edited = ?, deleted = ?, event = ?, eventId = ?
                WHERE owner = ? AND peer = ? AND id = ?
                """, arguments: [m.mine ? 1 : 0, m.ts, m.text, m.music, m.replyTo, m.state, m.read ? 1 : 0, m.edited ? 1 : 0,
                                 m.deleted ? 1 : 0, m.event, m.eventId, m.owner, m.peer, m.id])
        }
    }

    private func get(_ me: String, _ peer: String, _ id: String) -> ChatMessage? {
        (try? db?.read { try Row.fetchOne($0, sql: "SELECT * FROM message WHERE owner = ? AND peer = ? AND id = ?", arguments: [me, peer, id]) })??
            .map(ChatMessage.init(row:))
    }

    private func setState(_ m: ChatMessage, _ state: Int) {
        try? db?.write { try $0.execute(sql: "UPDATE message SET state = ? WHERE owner = ? AND peer = ? AND id = ?", arguments: [state, m.owner, m.peer, m.id]) }
        changed()
    }

    private func apply(me: String, author: String, event: NostrEvent, o: JSONObject, history: Bool = false) {
        guard let id = o.str("id"), !id.isEmpty, id.count <= 64 else { return }
        // Часы отправителя, но не позже минуты после получения релеем.
        let ts: Int64 = {
            if let v = o.int("ts"), v > 0 { return min(Int64(v), event.createdAt * 1000 + 60_000) }
            return event.createdAt * 1000
        }()
        let text = String((o.str("text") ?? "").prefix(Self.maxText))
        switch o.str("k") {
        case Self.kMsg:
            typing[author] = nil
            let reading = history || (openPeer == author && UIApplication.shared.applicationState == .active)
            let music = o.obj("m").flatMap(ChatMusic.init(object:)).map { JSON.string($0.json) }
            let m = ChatMessage(owner: me, peer: author, id: id, mine: false, ts: ts, text: text, music: music,
                                replyTo: o.str("re").flatMap { $0.isEmpty ? nil : $0 }, state: ChatMessage.stateReceived, read: reading)
            guard insert(m) else { return }
            if history { break }
            if reading { sendRead(author, upTo: ts) } else { ChatNotifier.notify(from: friends.friends.first { $0.pubkey == author }?.name ?? "", text: text.isEmpty ? (m.card?.label ?? "") : Stickers.plain(text)) }
        case Self.kEdit:
            if let old = get(me, author, id) {
                if !old.mine && !old.deleted {
                    var u = old
                    u.text = text
                    u.edited = true
                    update(u)
                }
            } else {
                _ = insert(ChatMessage(owner: me, peer: author, id: id, mine: false, ts: ts, text: text, edited: true))
            }
        case Self.kDel:
            try? db?.write { try $0.execute(sql: "DELETE FROM reaction WHERE owner = ? AND peer = ? AND msgId = ?", arguments: [me, author, id]) }
            if let old = get(me, author, id) {
                if !old.mine {
                    var u = old
                    u.text = ""
                    u.music = nil
                    u.deleted = true
                    update(u)
                }
            } else {
                _ = insert(ChatMessage(owner: me, peer: author, id: id, mine: false, ts: ts, text: "", deleted: true))
            }
        case Self.kRead:
            let upTo = Int64(o.int("upTo") ?? 0)
            try? db?.write { try $0.execute(sql: "UPDATE message SET read = 1 WHERE owner = ? AND peer = ? AND mine = 1 AND ts <= ?", arguments: [me, author, upTo]) }
        default:
            // Сообщение более новой версии: показывается, если в нём есть текст.
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return }
            if insert(ChatMessage(owner: me, peer: author, id: id, mine: false, ts: ts, text: text, read: history)), !history {
                ChatNotifier.notify(from: friends.friends.first { $0.pubkey == author }?.name ?? "", text: text)
            }
        }
        changed()
    }

    // MARK: - Отправка

    private func payload(_ kind: String, _ id: String) -> JSONObject {
        ["t": Self.type, "v": Self.protocolVersion, "k": kind, "id": id]
    }

    private func sign(_ peer: String, kind: Int, content: JSONObject) -> NostrEvent? {
        guard let sk = friends.secretKey, let encrypted = Nostr.encrypt(privateKey: sk, to: peer, plain: JSON.string(content)) else { return nil }
        return Nostr.sign(privateKey: sk, kind: kind, tags: [["p", peer]], content: encrypted)
    }

    /// Сообщение: текст и/или карточка. Ссылка на трек, альбом или плейлист в тексте становится карточкой.
    func send(_ peer: String, text: String, music: [ChatMusic] = [], replyTo: String? = nil) {
        guard let me = me else { return }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var cards = music
        if cards.isEmpty, let (range, target) = Self.findLink(body) {
            cards.append(ChatMusic(kind: target.kind, id: target.id, title: target.title ?? "", by: target.by ?? ""))
            body.removeSubrange(range)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let items: [(String, ChatMusic?)] = cards.isEmpty ? [(body, nil)] : cards.enumerated().map { ($0.offset == 0 ? body : "", $0.element) }
        for (i, item) in items.enumerated() where !item.0.isEmpty || item.1 != nil {
            let ts = max(Self.nowMs(), lastSentTs + 1)
            lastSentTs = ts
            let draft = ChatMessage(owner: me, peer: peer, id: UUID().uuidString.lowercased(), mine: true, ts: ts,
                                    text: String(item.0.prefix(Self.maxText)), music: item.1.map { JSON.string($0.json) },
                                    replyTo: i == 0 ? replyTo : nil, state: ChatMessage.stateSending)
            _ = insert(draft)
            changed()
            guard let event = signMessage(draft) else { continue }
            var m = draft
            m.event = JSON.string(event.json)
            m.eventId = event.id
            update(m)
            deliver(m, event)
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func findLink(_ text: String) -> (Range<String.Index>, AppLinks.Target)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = m.url, let target = AppLinks.parse(url), let r = Range(m.range, in: text) else { continue }
            return (r, target)
        }
        return nil
    }

    private func signMessage(_ m: ChatMessage) -> NostrEvent? {
        var content = payload(Self.kMsg, m.id)
        content["ts"] = m.ts
        content["text"] = m.text
        if let c = m.card { content["m"] = c.json }
        if let r = m.replyTo { content["re"] = r }
        return sign(m.peer, kind: Self.kindDM, content: content)
    }

    /// Отправляет событие и помечает сообщение отправленным у первого релея, который его принял; через 20 с без OK — «не отправлено».
    private func deliver(_ m: ChatMessage, _ event: NostrEvent) {
        guard delivering.insert(m.id).inserted else { return }
        var accepted = false
        relays.publish(event) { [weak self] _, ok, _ in
            guard ok, !accepted else { return }
            accepted = true
            self?.setState(m, ChatMessage.stateSent)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendTimeout) { [weak self] in
            self?.delivering.remove(m.id)
            if !accepted { self?.setState(m, ChatMessage.stateFailed) }
        }
    }

    func retry(_ m: ChatMessage) {
        let event = m.event.flatMap { JSON.object($0) }.flatMap(NostrEvent.init(json:)) ?? signMessage(m)
        guard let e = event else { return }
        var u = m
        u.event = JSON.string(e.json)
        u.eventId = e.id
        u.state = ChatMessage.stateSending
        update(u)
        changed()
        deliver(u, e)
    }

    private var retryScheduled = false

    private func retrySoon() {
        guard me != nil, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.retryScheduled = false
            self?.retryOutbox()
        }
    }

    /// Что не ушло — уходит, когда релей снова доступен (как в Telegram).
    private func retryOutbox() {
        guard let me = me, let db = db else { return }
        let pending: [ChatMessage] = (try? db.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM message WHERE owner = ? AND mine = 1 AND deleted = 0 AND state IN (0, 2)", arguments: [me])
                .map(ChatMessage.init(row:))
        }) ?? []
        for m in pending { retry(m) }
    }

    func edit(_ m: ChatMessage, newText: String) {
        let text = String(newText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxText))
        guard m.mine, !text.isEmpty, text != m.text else { return }
        var u = m
        u.text = text
        u.edited = true
        update(u)
        changed()
        var content = payload(Self.kEdit, m.id)
        content["ts"] = Self.nowMs()
        content["text"] = text
        if let e = sign(m.peer, kind: Self.kindDM, content: content) { relays.publish(e) }
    }

    /// Удалить у себя; `forBoth` (свои) — и у друга, и релеи просят удалить исходное событие (kind 5).
    func delete(_ m: ChatMessage, forBoth: Bool) {
        var u = m
        u.text = ""
        u.music = nil
        u.deleted = true
        u.event = nil
        update(u)
        try? db?.write { try $0.execute(sql: "DELETE FROM reaction WHERE owner = ? AND peer = ? AND msgId = ?", arguments: [m.owner, m.peer, m.id]) }
        changed()
        guard forBoth, m.mine else { return }
        var content = payload(Self.kDel, m.id)
        content["ts"] = Self.nowMs()
        if let e = sign(m.peer, kind: Self.kindDM, content: content) { relays.publish(e) }
        if let sk = friends.secretKey, let eventId = m.eventId {
            relays.publish(Nostr.sign(privateKey: sk, kind: Self.kindDelete, tags: [["e", eventId]], content: ""))
        }
    }

    /// «Прочитано» до момента `upTo` (если пользователь не выключил отчёты о прочтении).
    private func sendRead(_ peer: String, upTo: Int64) {
        guard friends.privacy.readReceipts else { return }
        var content = payload(Self.kRead, UUID().uuidString.lowercased())
        content["upTo"] = upTo
        if let e = sign(peer, kind: Self.kindDM, content: content) { relays.publish(e) }
    }

    /// «Печатает…»: не чаще раза в 4 с, событие эфемерное (kind 21004).
    func typingNow(_ peer: String) {
        if let last = lastTypingSent[peer], Date().timeIntervalSince(last) < Self.typingEvery { return }
        lastTypingSent[peer] = Date()
        var content = payload(Self.kTyping, "t")
        content["ts"] = Self.nowMs()
        if let e = sign(peer, kind: Self.kindTyping, content: content) { relays.publish(e) }
    }

    func isTyping(_ peer: String) -> Bool { (typing[peer] ?? .distantPast) > Date() }

    // MARK: - Реакции (полный текущий набор, ≤ 3, с задержкой 1,2 с)

    func react(_ m: ChatMessage, key: String) {
        guard let me = me, !m.deleted, let db = db else { return }
        let old = reactions(m.peer)[m.id]?.first { $0.reactor == me }
        var keys = old?.keyList ?? []
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else {
            keys.append(key)
            if keys.count > 3 { keys.removeFirst(keys.count - 3) }
        }
        let ts = max(Self.nowMs(), (old?.ts ?? 0) + 1)
        try? db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO reaction (owner, peer, msgId, reactor, keys, ts, state, event) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
                           arguments: [me, m.peer, m.id, me, keys.joined(separator: "\n"), ts, ChatMessage.stateSending])
        }
        changed()
        let jobKey = m.peer + ":" + m.id
        reactionWork[jobKey]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reactionWork[jobKey] = nil
            var content: JSONObject = ["t": Self.typeReact, "v": Self.protocolVersion, "id": m.id, "ts": ts, "r": keys]
            content["ts"] = ts
            guard let e = self.sign(m.peer, kind: Self.kindDM, content: content) else { return }
            try? db.write {
                try $0.execute(sql: "UPDATE reaction SET event = ? WHERE owner = ? AND peer = ? AND msgId = ? AND reactor = ?",
                               arguments: [JSON.string(e.json), me, m.peer, m.id, me])
            }
            self.relays.publish(e) { _, ok, _ in
                guard ok else { return }
                try? db.write {
                    try $0.execute(sql: "UPDATE reaction SET state = ? WHERE owner = ? AND peer = ? AND msgId = ? AND reactor = ? AND ts = ?",
                                   arguments: [ChatMessage.stateSent, me, m.peer, m.id, me, ts])
                }
            }
        }
        reactionWork[jobKey] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactDebounce, execute: work)
    }

    private func applyReaction(me: String, author: String, event: NostrEvent, o: JSONObject) {
        guard let msgId = o.str("id"), let db = db else { return }
        let ts = Int64(o.int("ts") ?? Int(event.createdAt * 1000))
        let keys = ((o.arr("r") as? [String]) ?? []).prefix(3)
        let old = (try? db.read { try Int64.fetchOne($0, sql: "SELECT ts FROM reaction WHERE owner = ? AND peer = ? AND msgId = ? AND reactor = ?", arguments: [me, author, msgId, author]) }) ?? nil
        if let o = old, o >= ts { return }
        try? db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO reaction (owner, peer, msgId, reactor, keys, ts, state, event) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
                           arguments: [me, author, msgId, author, keys.joined(separator: "\n"), ts, ChatMessage.stateReceived])
        }
        changed()
    }

    // MARK: - Собеседники: добавил ли меня, есть ли чаты

    private func loadPeers() -> [String: PeerStatus] {
        guard let o = JSON.object(store.string("peers") ?? "{}") else { return [:] }
        var out: [String: PeerStatus] = [:]
        for (k, v) in o {
            guard let p = v as? JSONObject else { continue }
            out[k] = PeerStatus(addedMe: p.bool("a") ?? false, proto: p.int("c") ?? 0, version: p.str("p"))
        }
        return out
    }

    private func notePeer(_ pubkey: String, proto: Int) {
        var s = peers[pubkey] ?? PeerStatus(addedMe: true, proto: 0, version: nil)
        guard proto > s.proto || !s.addedMe else { return }
        s.proto = max(s.proto, proto)
        s.addedMe = true
        peers[pubkey] = s
        var o: JSONObject = [:]
        for (k, v) in peers {
            var e: JSONObject = ["a": v.addedMe, "c": v.proto]
            if let p = v.version { e["p"] = p }
            o[k] = e
        }
        store.setString(JSON.string(o), for: "peers")
    }
}

/// Стикеры в тексте — токен U+E000 <id> U+E001 (`friends/Stickers.kt`). Картинок стикеров на iOS пока нет: показывается подпись.
enum Stickers {
    static let start: Character = "\u{E000}"
    static let end: Character = "\u{E001}"

    /// Текст для уведомлений и превью: стикер становится своим кодом (как `Stickers.plain` на Android).
    static func plain(_ text: String) -> String {
        var out = ""
        var id = ""
        var inSticker = false
        for c in text {
            if c == start { inSticker = true; id = ""; continue }
            if c == end {
                inSticker = false
                out += StickerStore.byId[id]?.code ?? L("ios_sticker")
                continue
            }
            if inSticker { id.append(c) } else { out.append(c) }
        }
        return out
    }
}

/// Локальные уведомления о новых сообщениях.
enum ChatNotifier {
    static func notify(from name: String, text: String) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { notify(from: name, text: text) } }
        guard UIApplication.shared.applicationState != .active else { return }
        // «Уведомления о сообщениях» (Настройки → Сообщения, SharedPreferences `chat`, ключ `notify`).
        if UserDefaults(suiteName: "sp.chat")?.object(forKey: "notify") as? Bool == false { return }
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "Drxwnify" : name
        content.body = text
        content.sound = .default
        content.threadIdentifier = "chat_messages"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func requestPermission() {
        #if DEBUG
        // Проверка экранов на симуляторе (DRX_SCREEN): системный запрос закрыл бы экран, нажать его там нечем.
        if ProcessInfo.processInfo.environment["DRX_SCREEN"] != nil { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
