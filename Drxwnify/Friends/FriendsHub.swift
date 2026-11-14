import Foundation
import Combine
import GRDB
import zlib

/// Друзья поверх Nostr — перенос `friends/FriendsHub.kt` (CRITICAL §1.3).
/// Хранение — общие настройки `friends` (как SharedPreferences на Android, переносятся резервной копией); ключ — в Keychain.
final class FriendsHub: ObservableObject {
    enum Audience: String, CaseIterable, Codable {
        case NOBODY, VERIFIED, FRIENDS, EVERYONE

        var rank: Int { Audience.allCases.firstIndex(of: self) ?? 0 }
    }

    struct Privacy: Equatable {
        var nowPlaying = Audience.FRIENDS
        var history = Audience.FRIENDS
        var playlists = Audience.FRIENDS
        var stats = Audience.FRIENDS
        var discoverable = false
        var listenAlong = true
        var readReceipts = true
    }

    struct Profile: Equatable {
        var pubkey: String
        var name: String
        var avatar: String?

        var code: String { Nostr.npub(pubkey) ?? pubkey }
        var isDeveloper: Bool { pubkey == FriendsHub.developerPubkey }
    }

    struct Friend: Identifiable, Equatable {
        var pubkey: String
        var name: String
        var addedAt: Int64
        var id: String { pubkey }
    }

    struct TrackRef: Hashable {
        var title: String
        var artist: String
        var catalogId: String?
        var mediaId: String?
        var cover: String?
        var durationMs: Int64 = 0
        var at: Int64 = 0

        /// Трек для плеера: трек каталога — `mfb:<id>`, иначе media id как есть.
        var track: Track {
            let id = catalogId.map(FallbackIds.of) ?? mediaId ?? "ref:\(title)|\(artist)"
            return Track(id: id, catalogId: catalogId, title: title,
                         artists: artist.components(separatedBy: ", ").filter { !$0.isEmpty }.map { Track.Artist(id: nil, name: $0) },
                         albumId: nil, albumName: nil, durationMs: Int(durationMs), artworkUrl: cover)
        }
    }

    struct NowPlaying: Equatable {
        var track: TrackRef
        var positionMs: Int64
        var playing: Bool
        var at: Int64
        var listenAlong: Bool

        func positionNow() -> Int64 { playing ? positionMs + max(0, FriendsHub.nowMs() - at) : positionMs }

        /// Играет прямо сейчас (Android 2.3.0 `isLive`): последнее слово «играет» и трек ещё не должен был закончиться
        /// (+3 мин на часы и сеть; без длины — 12 мин). Друг, у которого систему убила приложение, не висит «в эфире» часами.
        func isLive(_ nowMs: Int64 = FriendsHub.nowMs()) -> Bool {
            guard playing else { return false }
            let left = track.durationMs > 0 ? max(0, track.durationMs - positionMs) : 12 * 60_000
            return nowMs <= at + left + 3 * 60_000
        }
    }

    struct SharedPlaylist: Hashable {
        var name: String
        var total: Int
        var tracks: [TrackRef]
    }

    struct SharedLikes: Equatable {
        var total: Int
        var source: String?
        var tracks: [TrackRef]
    }

    struct Stats: Equatable {
        var weekMinutes: Int
        var weekPlays: Int
        var likedCount: Int
        var topArtists: [(String, Int)]

        static func == (a: Stats, b: Stats) -> Bool {
            a.weekMinutes == b.weekMinutes && a.weekPlays == b.weekPlays && a.likedCount == b.likedCount
                && a.topArtists.map { $0.0 } == b.topArtists.map { $0.0 } && a.topArtists.map { $0.1 } == b.topArtists.map { $0.1 }
        }
    }

    struct FriendData: Equatable {
        var name: String?
        var avatar: String?
        var now: NowPlaying?
        var history: [TrackRef]?
        var playlists: [SharedPlaylist]?
        var stats: Stats?
        var likes: SharedLikes?
        var stamps: [String: Int64] = [:]
    }

    struct FriendRequest: Identifiable, Equatable {
        var pubkey: String
        var name: String
        var at: Int64
        var id: String { pubkey }
    }

    struct Found: Identifiable {
        var pubkey: String
        var name: String
        var avatar: String?
        var id: String { pubkey }
    }

    static let developerPubkey = "e114d6d2c422913fbb0c5b525cf927015aaecdfbea72fadd5c1dd2693f1c7f74"
    static let developerName = "drxwnslvt"
    static let inviteBase = "https://drxwnify.pages.dev/add/"

    private static let dPrefix = "drxw:"
    private static let fProfile = "profile", fNow = "now", fHistory = "history", fPlaylists = "playlists", fStats = "stats"
    private static let fHello = "hello", fLikes = "likes", fPortrait = "portrait", fVerified = "verified"
    private static let dataFields = [fNow, fHistory, fPlaylists, fStats, fLikes, fPortrait]

    private static let nowDebounce: TimeInterval = 1.5
    private static let libraryRefreshMs: Int64 = 6 * 3600 * 1000
    private static let historyPublishDelay: TimeInterval = 120
    private static let maxHistory = 50
    static let maxLikes = 500
    private static let maxLikesPacked = 45_000
    private static let likesPackedPrefix = "gz1:"
    private static let likesRepublishMs: Int64 = 3 * 24 * 3600 * 1000
    private static let searchWait: TimeInterval = 4
    private static let maxPlaylists = 10
    private static let maxPlaylistTracks = 50
    private static let maxFriendsEncrypted = 40
    private static let maxAvatarChars = 60_000

    @Published private(set) var profile: Profile?
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var privacy = Privacy()
    @Published private(set) var data: [String: FriendData] = [:]
    @Published private(set) var requests: [FriendRequest] = []
    @Published private(set) var listeningTo: String?
    @Published private(set) var verified: Set<String> = []
    @Published private(set) var pinned: [String] = []
    /// Ссылка-приглашение, открытая снаружи: ждёт ответа «добавить / нет».
    @Published var invite: (pubkey: String, name: String)?

    private let store: TypedStore
    private let database: AppDatabase
    private let relays = RelayPool.shared
    private(set) var secretKey: [UInt8]?
    private var liveUsers = 0
    private var liveSubs: [String] = []
    private var newestSeen: Int64 = 0
    private var liveFriendKeys = Set<String>()
    private var lastNow: NowPlaying?
    private var nowWork: DispatchWorkItem?
    private var historyWork: DispatchWorkItem?
    /// Слушать вместе с другом: новые данные `now` друга передаются сюда.
    var onFriendNow: ((NowPlaying) -> Void)?
    /// Друзья изменились — чатам нужен новый список отправителей.
    var onFriendsChanged: (() -> Void)?

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    init(prefs: Prefs, database: AppDatabase) {
        store = prefs.shared("friends")
        self.database = database
        load()
    }

    /// Состояние из настроек (после запуска и после восстановления резервной копии).
    func load() {
        if let hex = store.string("sk"), let sk = [UInt8](hexString: hex), sk.count == 32 {
            secretKey = sk
            profile = Profile(pubkey: Secp256k1.publicKey(sk).hex, name: store.string("name") ?? "", avatar: store.string("avatar"))
        } else {
            secretKey = nil
            profile = nil
        }
        friends = ((JSON.array(Data((store.string("friends") ?? "[]").utf8)) as? [JSONObject]) ?? []).compactMap { o in
            guard let p = o.str("p") else { return nil }
            return Friend(pubkey: p, name: o.str("n") ?? "", addedAt: Int64(o.int("t") ?? 0))
        }
        privacy = Self.privacy(from: JSON.object(store.string("privacy") ?? "{}") ?? [:])
        verified = Set(store.stringSet("verifiedSet") ?? [])
        pinned = (JSON.array(Data((store.string("pinned") ?? "[]").utf8)) as? [String]) ?? []
        dropSelfFromFriends()
        ensureDeveloperFriend()
        if secretKey != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.publishLibraryIfStale(Self.libraryRefreshMs) }
        }
    }

    var hasProfile: Bool { secretKey != nil }

    // MARK: - Профиль

    func createProfile(name: String) {
        saveKey(Secp256k1.newPrivateKey(), name: name.trimmingCharacters(in: .whitespaces))
        ensureDeveloperFriend()
        publishProfile()
        publishLibrary()
    }

    /// Восстановление по ключу (nsec), с заменой текущего профиля; false — ключ неверный.
    @discardableResult
    func importProfile(nsec: String, name: String) -> Bool {
        guard let (hrp, bytes) = Nostr.bech32Decode(nsec), hrp == "nsec", bytes.count == 32 else { return false }
        let pub = Secp256k1.publicKey(bytes).hex
        let finalName = pub == Self.developerPubkey ? Self.developerName
            : (!name.trimmingCharacters(in: .whitespaces).isEmpty ? name.trimmingCharacters(in: .whitespaces) : (profile?.name ?? ""))
        if pub != profile?.pubkey {
            store.remove("avatar")
            store.remove("devPublic")
        }
        saveKey(bytes, name: finalName)
        if pub == Self.developerPubkey && store.bool("devPublic") != true {
            store.setBool(true, for: "devPublic")
            setPrivacy(Privacy(nowPlaying: .EVERYONE, history: .EVERYONE, playlists: .EVERYONE, stats: .EVERYONE, discoverable: true, listenAlong: true))
        }
        dropSelfFromFriends()
        ensureDeveloperFriend()
        restartLive()
        publishProfile()
        publishLibrary()
        return true
    }

    func rename(_ name: String) {
        guard let sk = secretKey else { return }
        saveKey(sk, name: name.trimmingCharacters(in: .whitespaces))
        publishProfile()
    }

    /// Аватар: квадрат 160 px в JPEG, base64 (как на Android).
    func setAvatar(jpegBase64: String?) {
        if let a = jpegBase64 { store.setString(a, for: "avatar") } else { store.remove("avatar") }
        profile?.avatar = jpegBase64
        publishProfile()
    }

    /// Резервный ключ: кто им владеет, тот и есть этот профиль.
    func backupKey() -> String? { secretKey.map { Nostr.bech32Encode(hrp: "nsec", data: $0) } }

    private func saveKey(_ sk: [UInt8], name: String) {
        let pub = Secp256k1.publicKey(sk).hex
        if pub != profile?.pubkey {
            store.remove("verifiedFor")
            store.remove("iAmVerified")
        }
        secretKey = sk
        store.setString(sk.hex, for: "sk")
        store.setString(name, for: "name")
        profile = Profile(pubkey: pub, name: name, avatar: store.string("avatar"))
    }

    func inviteLink() -> String? {
        guard let me = profile else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let name = me.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return Self.inviteBase + me.code + (me.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "?n=" + name)
    }

    /// Приглашение из ссылки `drxwnify.pages.dev/add/<npub>` или `drxwnify://add/<npub>`.
    func parseInvite(_ url: URL) -> (pubkey: String, name: String)? {
        let isSite = url.host == "drxwnify.pages.dev" && url.path.hasPrefix("/add/")
        let isScheme = url.scheme == "drxwnify" && (url.host == "add" || url.path.hasPrefix("/add"))
        guard isSite || isScheme, let pub = parseCode(url.absoluteString) else { return nil }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value ?? ""
        return (pub, String(name.prefix(40)))
    }

    func openInvite(_ url: URL) -> Bool {
        guard let inv = parseInvite(url) else { return false }
        if inv.pubkey != profile?.pubkey { invite = inv }
        return true
    }

    func answerInvite(accept: Bool) {
        guard let inv = invite else { return }
        invite = nil
        if accept { addFriend(inv.pubkey, name: inv.name) }
    }

    // MARK: - Приватность

    func setPrivacy(_ p: Privacy) {
        let before = privacy
        privacy = p
        store.setString(JSON.string(Self.privacyJSON(p)), for: "privacy")
        // То, что больше не показывается кому-то, перезаписывается пустым.
        func narrowed(_ old: Audience, _ new: Audience) -> Bool { new.rank < old.rank }
        if narrowed(before.nowPlaying, p.nowPlaying) { clearField(Self.fNow, before.nowPlaying) }
        if narrowed(before.history, p.history) { clearField(Self.fHistory, before.history) }
        if narrowed(before.playlists, p.playlists) { clearField(Self.fPlaylists, before.playlists) }
        if narrowed(before.stats, p.stats) { clearField(Self.fStats, before.stats) }
        if before.discoverable != p.discoverable { publishProfile() }
        publishLibrary()
        if let n = lastNow { publishNow(n) }
    }

    // MARK: - Друзья

    /// Ключ из кода друга: npub, ссылка с ним или 64 символа hex.
    func parseCode(_ code: String) -> String? {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let re = try? NSRegularExpression(pattern: "npub1[02-9ac-hj-np-z]{58}"),
           let m = re.firstMatch(in: text.lowercased(), range: NSRange(text.lowercased().startIndex..., in: text.lowercased())),
           let r = Range(m.range, in: text.lowercased()) {
            let npub = String(text.lowercased()[r])
            if let (hrp, bytes) = Nostr.bech32Decode(npub), hrp == "npub", Secp256k1.isValidPublicKey(bytes) { return bytes.hex }
        }
        if text.count == 64, let b = [UInt8](hexString: text), Secp256k1.isValidPublicKey(b) { return text.lowercased() }
        return nil
    }

    /// Добавляет друга; он получает запрос с именем этого профиля.
    func addFriend(_ pubkey: String, name: String = "") {
        guard let me = profile, pubkey != me.pubkey, !friends.contains(where: { $0.pubkey == pubkey }) else { return }
        let known = !name.isEmpty ? name : (data[pubkey]?.name ?? requests.first { $0.pubkey == pubkey }?.name ?? "")
        friends.append(Friend(pubkey: pubkey, name: known, addedAt: Self.nowMs()))
        requests.removeAll { $0.pubkey == pubkey }
        saveFriends()
        publishTo(pubkey, Self.fHello, helloContent(me.name))
        publishLibrary(onlyFor: pubkey)
        if let n = lastNow { publishNow(n) }
        restartLive()
        onFriendsChanged?()
    }

    func removeFriend(_ pubkey: String) {
        friends.removeAll { $0.pubkey == pubkey }
        saveFriends()
        if pinned.contains(pubkey) { togglePinned(pubkey) }
        if listeningTo == pubkey { stopListenAlong() }
        for f in Self.dataFields + [Self.fHello] { publishTo(pubkey, f, "") }
        restartLive()
        onFriendsChanged?()
    }

    func dismissRequest(_ pubkey: String) {
        requests.removeAll { $0.pubkey == pubkey }
        store.setStringSet((store.stringSet("dismissed") ?? []) + [pubkey], for: "dismissed")
    }

    @discardableResult
    func togglePinned(_ pubkey: String) -> Bool {
        if pinned.contains(pubkey) { pinned.removeAll { $0 == pubkey } } else { pinned.append(pubkey) }
        store.setString(JSON.string(pinned), for: "pinned")
        return pinned.contains(pubkey)
    }

    func isVerified(_ pubkey: String) -> Bool { verified.contains(pubkey) }
    /// Меня отметил разработчик (красная метка) — или я сам разработчик: видна вкладка «drxwnslvt's».
    var selfVerified: Bool {
        guard let me = profile else { return false }
        return me.isDeveloper || store.string("verifiedFor") == me.pubkey
    }

    private func saveFriends() {
        store.setString(JSON.string(friends.map { ["p": $0.pubkey, "n": $0.name, "t": $0.addedAt] as [String: Any] }), for: "friends")
    }

    private func dropSelfFromFriends() {
        guard let me = profile?.pubkey, friends.contains(where: { $0.pubkey == me }) else { return }
        friends.removeAll { $0.pubkey == me }
        saveFriends()
    }

    /// Разработчик у всех в друзьях с самого начала — один раз: удалённый, он больше не возвращается.
    private func ensureDeveloperFriend() {
        guard let me = profile, !me.isDeveloper else { return }
        if store.bool("devAdded") != true {
            store.setBool(true, for: "devAdded")
            if !friends.contains(where: { $0.pubkey == Self.developerPubkey }) {
                friends.append(Friend(pubkey: Self.developerPubkey, name: Self.developerName, addedAt: Self.nowMs()))
                saveFriends()
            }
        }
        sayHelloToDeveloper()
    }

    /// Разработчик получает один раз на профиль тот же запрос, что при обычном добавлении.
    private func sayHelloToDeveloper() {
        guard let me = profile, !me.isDeveloper, store.string("devHelloFor") != me.pubkey,
              friends.contains(where: { $0.pubkey == Self.developerPubkey }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.profile?.pubkey == me.pubkey, self.friends.contains(where: { $0.pubkey == Self.developerPubkey }) else { return }
            self.publishTo(Self.developerPubkey, Self.fHello, self.helloContent(self.profile?.name ?? ""))
            self.publishLibrary(onlyFor: Self.developerPubkey)
            self.store.setString(me.pubkey, for: "devHelloFor")
        }
    }

    // MARK: - Живые обновления

    /// Экран с друзьями открыт: данные приходят, пока открыт хоть один.
    func startLive() {
        liveUsers += 1
        if liveUsers == 1 { openLive() }
        publishLibraryIfStale(10 * 60 * 1000)
    }

    func stopLive() {
        liveUsers = max(0, liveUsers - 1)
        if liveUsers == 0 && listeningTo == nil { closeLive() }
    }

    private func restartLive() {
        guard !liveSubs.isEmpty else { return }
        closeLive()
        openLive()
    }

    private func openLive() {
        guard let me = profile?.pubkey else { return }
        var keys = friends.map { $0.pubkey } + [Self.developerPubkey, me]
        var seenKeys = Set<String>()
        keys = keys.filter { seenKeys.insert($0).inserted }
        var dValues = [Self.dPrefix + Self.fProfile]
        for f in Self.dataFields {
            dValues.append(Self.dPrefix + f)
            dValues.append("\(Self.dPrefix)\(f):\(me)")
        }
        dValues.append("\(Self.dPrefix)\(Self.fVerified):\(me)")
        if profile?.isDeveloper == true { for f in friends { dValues.append("\(Self.dPrefix)\(Self.fVerified):\(f.pubkey)") } }
        var filter: JSONObject = ["kinds": [Nostr.kindAppData], "authors": keys, "#d": dValues]
        if newestSeen > 0 && liveFriendKeys == Set(keys) { filter["since"] = newestSeen - 60 }
        liveFriendKeys = Set(keys)
        liveSubs.append(relays.subscribe([filter]) { [weak self] in self?.onEvent($0) })
        let toMe: JSONObject = ["kinds": [Nostr.kindAppData], "#p": [me], "since": Int64(Date().timeIntervalSince1970) - 60 * 24 * 3600]
        liveSubs.append(relays.subscribe([toMe]) { [weak self] in self?.onEvent($0) })
    }

    private func closeLive() {
        liveSubs.forEach(relays.close)
        liveSubs.removeAll()
    }

    private func onEvent(_ event: NostrEvent) {
        guard let me = profile?.pubkey, let sk = secretKey, let d = event.tag("d"), d.hasPrefix(Self.dPrefix) else { return }
        let parts = String(d.dropFirst(Self.dPrefix.count)).components(separatedBy: ":")
        let field = parts[0]
        let personal = parts.count > 1 ? parts[1] : nil
        if field == Self.fVerified, let target = personal {
            onVerification(event, me: me, sk: sk, target: target)
            return
        }
        if let p = personal, p != me { return }
        let content: String
        if personal != nil && !event.content.isEmpty {
            guard let plain = Nostr.decrypt(privateKey: sk, from: event.pubkey, payload: event.content) else { return }
            content = plain
        } else {
            content = event.content
        }
        let author = event.pubkey
        if field == Self.fHello {
            let isFriend = friends.contains { $0.pubkey == author }
            let dismissed = store.stringSet("dismissed") ?? []
            if content.isEmpty || isFriend || dismissed.contains(author) { return }
            let name = JSON.object(content)?.str("name") ?? ""
            if !requests.contains(where: { $0.pubkey == author }) {
                requests.append(FriendRequest(pubkey: author, name: name, at: event.createdAt * 1000))
            }
            return
        }
        // Друзья и открытый профиль разработчика, который видят все.
        guard friends.contains(where: { $0.pubkey == author }) || author == Self.developerPubkey || author == me else { return }
        var current = data[author] ?? FriendData()
        // То же событие ещё раз (другой релей, новое открытие экрана): делать нечего.
        if (current.stamps[field] ?? 0) >= event.createdAt { return }
        newestSeen = max(newestSeen, event.createdAt)
        current.stamps[field] = event.createdAt
        let json = content.trimmingCharacters(in: .whitespaces).isEmpty ? nil : JSON.object(content)
        switch field {
        case Self.fProfile:
            if let n = json?.str("name"), !n.trimmingCharacters(in: .whitespaces).isEmpty { current.name = n }
            if let pic = json?.str("pic"), !pic.isEmpty, pic.count <= Self.maxAvatarChars { current.avatar = pic }
        case Self.fNow: current.now = json.flatMap(Self.now(from:))
        case Self.fHistory: current.history = (json?.arr("tracks") as? [JSONObject]).map { $0.map(Self.ref(from:)) }
        case Self.fPlaylists: current.playlists = (json?.arr("playlists") as? [JSONObject]).map(Self.playlists(from:))
        case Self.fStats: current.stats = json.map(Self.stats(from:))
        case Self.fLikes: current.likes = content.isEmpty ? nil : Self.unpackLikes(content)
        case Self.fPortrait: break
        default: return
        }
        data[author] = current
        if field == Self.fProfile, let n = current.name, let i = friends.firstIndex(where: { $0.pubkey == author }), friends[i].name != n {
            friends[i].name = n
            saveFriends()
        }
        if field == Self.fNow, listeningTo == author, let n = current.now { onFriendNow?(n) }
    }

    private var verificationStamps: [String: Int64] = [:]

    private func onVerification(_ event: NostrEvent, me: String, sk: [UInt8], target: String) {
        let key = "\(event.pubkey):\(target)"
        if (verificationStamps[key] ?? 0) > event.createdAt { return }
        verificationStamps[key] = event.createdAt
        func on(_ from: String) -> Bool {
            !event.content.isEmpty && Nostr.decrypt(privateKey: sk, from: from, payload: event.content).flatMap { JSON.object($0)?.int("v") } == 1
        }
        if event.pubkey == Self.developerPubkey && target == me {
            store.remove("iAmVerified")
            if on(Self.developerPubkey) { store.setString(me, for: "verifiedFor") } else { store.remove("verifiedFor") }
        } else if event.pubkey == me && profile?.isDeveloper == true {
            var updated = verified
            if on(target) { updated.insert(target) } else { updated.remove(target) }
            if updated != verified {
                verified = updated
                store.setStringSet(Array(updated), for: "verifiedSet")
            }
        }
    }

    /// Поиск профилей по нику: ждёт ответы релеев 4 с.
    func searchByName(_ query: String, completion: @escaping ([Found]) -> Void) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return completion([]) }
        let me = profile?.pubkey
        var found: [String: (Int64, Found)] = [:]
        let filter: JSONObject = ["kinds": [Nostr.kindAppData], "#d": [Self.dPrefix + Self.fProfile], "#t": ["drxwnify"], "limit": 500]
        let id = relays.subscribe([filter]) { event in
            guard let o = JSON.object(event.content) else { return }
            let name = (o.str("name") ?? "").trimmingCharacters(in: .whitespaces)
            let allowed = o.bool("find") == true || event.pubkey == Self.developerPubkey
            guard allowed, !name.isEmpty, event.pubkey != me, name.lowercased().contains(needle) else { return }
            if let prev = found[event.pubkey], prev.0 >= event.createdAt { return }
            let pic = o.str("pic").flatMap { !$0.isEmpty && $0.count <= Self.maxAvatarChars ? $0 : nil }
            found[event.pubkey] = (event.createdAt, Found(pubkey: event.pubkey, name: name, avatar: pic))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchWait) { [weak self] in
            self?.relays.close(id)
            let list = found.values.map { $0.1 }.sorted {
                let a = $0.name.lowercased().hasPrefix(needle), b = $1.name.lowercased().hasPrefix(needle)
                return a != b ? a : $0.name.count < $1.name.count
            }
            completion(Array(list.prefix(20)))
        }
    }

    // MARK: - Публикация

    /// «Я добавил тебя» с именем; `chat` — у этой версии есть чаты.
    private func helloContent(_ name: String) -> String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return JSON.string(["name": name, "chat": ChatHub.protocolVersion, "ver": String(version.prefix(16))] as [String: Any])
    }

    func sayHelloAgain(_ pubkey: String) {
        guard let me = profile, friends.contains(where: { $0.pubkey == pubkey }) else { return }
        publishTo(pubkey, Self.fHello, helloContent(me.name))
    }

    func helloTag(to: String) -> String { "\(Self.dPrefix)\(Self.fHello):\(to)" }

    private func publishTo(_ friend: String, _ field: String, _ content: String) {
        guard let sk = secretKey else { return }
        let encrypted = content.isEmpty ? "" : (Nostr.encrypt(privateKey: sk, to: friend, plain: content) ?? "")
        if !content.isEmpty && encrypted.isEmpty { return }
        let tags = [["d", "\(Self.dPrefix)\(field):\(friend)"], ["p", friend]]
        relays.publish(Nostr.sign(privateKey: sk, kind: Nostr.kindAppData, tags: tags, content: encrypted))
    }

    private func publishPublic(_ field: String, _ content: String) {
        guard let sk = secretKey else { return }
        relays.publish(Nostr.sign(privateKey: sk, kind: Nostr.kindAppData, tags: [["d", Self.dPrefix + field], ["t", "drxwnify"]], content: content))
    }

    private func publishField(_ field: String, _ content: String, _ audience: Audience, onlyFor: String? = nil) {
        switch audience {
        case .NOBODY: break
        case .EVERYONE: if onlyFor == nil { publishPublic(field, content) }
        case .FRIENDS:
            for f in friends.map({ $0.pubkey }).filter({ onlyFor == nil || $0 == onlyFor }).prefix(Self.maxFriendsEncrypted) { publishTo(f, field, content) }
        case .VERIFIED:
            for f in verified.filter({ onlyFor == nil || $0 == onlyFor }).prefix(Self.maxFriendsEncrypted) { publishTo(f, field, content) }
        }
    }

    private func clearField(_ field: String, _ was: Audience) {
        switch was {
        case .EVERYONE: publishPublic(field, "")
        case .FRIENDS: friends.forEach { publishTo($0.pubkey, field, "") }
        case .VERIFIED: verified.forEach { publishTo($0, field, "") }
        case .NOBODY: break
        }
    }

    private func publishProfile() {
        guard let sk = secretKey, let me = profile else { return }
        var p: [String: Any] = ["name": me.name, "find": privacy.discoverable]
        if let a = me.avatar { p["pic"] = a }
        publishPublic(Self.fProfile, JSON.string(p))
        let metadata = privacy.discoverable ? JSON.string(["name": me.name, "about": "Drxwnify"]) : "{}"
        relays.publish(Nostr.sign(privateKey: sk, kind: Nostr.kindMetadata, tags: [], content: metadata))
    }

    /// Из плеера: что играет сейчас (трек, пауза, перемотка). С задержкой 1,5 с.
    func playerChanged(track: Track?, positionMs: Int64, playing: Bool, durationMs: Int64) {
        guard secretKey != nil, let t = track else { return }
        nowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let now = NowPlaying(track: TrackRef(title: t.title, artist: t.artistNames, catalogId: t.catalogId,
                                                 mediaId: t.id.hasPrefix("local:") ? nil : t.id, cover: t.artworkUrl, durationMs: durationMs),
                                 positionMs: positionMs, playing: playing, at: Self.nowMs(), listenAlong: self.privacy.listenAlong)
            self.lastNow = now
            self.publishNow(now)
        }
        nowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.nowDebounce, execute: work)
    }

    private func publishNow(_ now: NowPlaying) {
        publishField(Self.fNow, JSON.string(Self.nowJSON(now)), privacy.nowPlaying)
    }

    /// Из плеера: прослушивание записано. История уходит друзьям через 2 минуты (несколько подряд — одним событием).
    func listened() {
        guard secretKey != nil, privacy.history != .NOBODY, historyWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.historyWork = nil
            self.publishHistory(self.privacy.history, onlyFor: nil)
        }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyPublishDelay, execute: work)
    }

    private func publishLibraryIfStale(_ maxAgeMs: Int64) {
        guard secretKey != nil else { return }
        let last = Int64(store.value("libraryAt").flatMap(Int.fromPref) ?? 0)
        if Self.nowMs() - last < maxAgeMs { return }
        publishLibrary()
    }

    /// История, плейлисты, лайки и статистика — каждому, кому разрешено настройками.
    func publishLibrary(onlyFor: String? = nil) {
        guard secretKey != nil else { return }
        let p = privacy
        if p.history != .NOBODY { publishHistory(p.history, onlyFor: onlyFor) }
        if p.playlists != .NOBODY {
            let playlists: [JSONObject] = ((try? database.pool.read { db -> [JSONObject] in
                let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM playlist ORDER BY createdAt ASC, rowid ASC LIMIT ?", arguments: [Self.maxPlaylists])
                return try rows.map { r in
                    let id: String = r["id"]
                    let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_song_map WHERE playlistId = ?", arguments: [id]) ?? 0
                    let refs = try Self.refs(db, sql: """
                        SELECT song.id, song.title, song.duration, song.thumbnailUrl FROM playlist_song_map m JOIN song ON song.id = m.songId
                        WHERE m.playlistId = ? ORDER BY m.position LIMIT ?
                        """, arguments: [id, Self.maxPlaylistTracks], withCover: false)
                    return ["n": r["name"] as String, "total": total, "tracks": refs.map(Self.refJSON)] as JSONObject
                }
            }) ?? [])
            publishField(Self.fPlaylists, JSON.string(["playlists": playlists]), p.playlists, onlyFor: onlyFor)
            publishLikes(p.playlists, onlyFor: onlyFor)
        }
        if p.stats != .NOBODY {
            let weekAgo = Self.nowMs() - 7 * 24 * 3600 * 1000
            let stats: JSONObject? = try? database.pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(playTime), 0) AS t, COUNT(*) AS n FROM event WHERE timestamp > ?", arguments: [weekAgo])
                let liked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? 0
                let top = try Row.fetchAll(db, sql: """
                    SELECT a.name AS name, COUNT(DISTINCT e.songId) AS c FROM event e JOIN song_artist_map m ON m.songId = e.songId
                    JOIN artist a ON a.id = m.artistId WHERE e.timestamp > ? GROUP BY a.id ORDER BY SUM(e.playTime) DESC LIMIT 5
                    """, arguments: [weekAgo]).map { ["n": $0["name"] as String, "c": $0["c"] as Int] as JSONObject }
                let total: Int64 = row?["t"] ?? 0
                return ["min": Int(total / 60000), "plays": row?["n"] as Int? ?? 0, "liked": liked, "top": top]
            }
            if let s = stats { publishField(Self.fStats, JSON.string(s), p.stats, onlyFor: onlyFor) }
        }
        if onlyFor == nil { store.setLong(Int(Self.nowMs()), for: "libraryAt") }
    }

    /// «Как меня видят» (Android 1.5.1): то, что получает зритель, которому открыты поля с рангом ≥ `minRank`
    /// (1 — отмеченный друг, 2 — друг, 3 — все).
    func preview(minRank: Int) -> FriendData {
        var d = FriendData()
        d.name = profile?.name
        d.avatar = profile?.avatar
        let p = privacy
        func open(_ a: Audience) -> Bool { a != .NOBODY && a.rank >= minRank }
        if open(p.nowPlaying) { d.now = lastNow }
        try? database.pool.read { db in
            if open(p.history) {
                d.history = try Self.refs(db, sql: """
                    SELECT song.id, song.title, song.duration, song.thumbnailUrl, MAX(e.timestamp) AS at FROM event e JOIN song ON song.id = e.songId
                    WHERE e.playTime >= MIN(30000, song.duration * 500) GROUP BY song.id ORDER BY at DESC LIMIT ?
                    """, arguments: [Self.maxHistory], withCover: true)
            }
            if open(p.playlists) {
                let likes = try Self.refs(db, sql: "SELECT id, title, duration, thumbnailUrl FROM song WHERE liked = 1 ORDER BY likedDate DESC LIMIT ?",
                                          arguments: [Self.maxLikes], withCover: true)
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? likes.count
                if !likes.isEmpty { d.likes = SharedLikes(total: total, source: nil, tracks: likes) }
                d.playlists = try Row.fetchAll(db, sql: "SELECT id, name FROM playlist ORDER BY createdAt ASC, rowid ASC LIMIT ?", arguments: [Self.maxPlaylists]).map { r in
                    let id: String = r["id"]
                    let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_song_map WHERE playlistId = ?", arguments: [id]) ?? 0
                    let refs = try Self.refs(db, sql: """
                        SELECT song.id, song.title, song.duration, song.thumbnailUrl FROM playlist_song_map m JOIN song ON song.id = m.songId
                        WHERE m.playlistId = ? ORDER BY m.position LIMIT ?
                        """, arguments: [id, Self.maxPlaylistTracks], withCover: false)
                    return SharedPlaylist(name: r["name"], total: n, tracks: refs)
                }
            }
            if open(p.stats) {
                let weekAgo = Self.nowMs() - 7 * 24 * 3600 * 1000
                let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(playTime), 0) AS t, COUNT(*) AS n FROM event WHERE timestamp > ?", arguments: [weekAgo])
                let liked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? 0
                let top = try Row.fetchAll(db, sql: """
                    SELECT a.name AS name, COUNT(DISTINCT e.songId) AS c FROM event e JOIN song_artist_map m ON m.songId = e.songId
                    JOIN artist a ON a.id = m.artistId WHERE e.timestamp > ? GROUP BY a.id ORDER BY SUM(e.playTime) DESC LIMIT 5
                    """, arguments: [weekAgo]).map { ($0["name"] as String, $0["c"] as Int) }
                let t: Int64 = row?["t"] ?? 0
                d.stats = Stats(weekMinutes: Int(t / 60000), weekPlays: row?["n"] ?? 0, likedCount: liked, topArtists: top)
            }
        }
        return d
    }

    private func publishHistory(_ audience: Audience, onlyFor: String?) {
        let refs: [TrackRef] = (try? database.pool.read { db in
            // Последние разные треки; прослушивание засчитано (как `Listening.counts`): ≥ 30 с или половина трека.
            try Self.refs(db, sql: """
                SELECT song.id, song.title, song.duration, song.thumbnailUrl, MAX(e.timestamp) AS at FROM event e JOIN song ON song.id = e.songId
                WHERE e.playTime >= MIN(30000, song.duration * 500) GROUP BY song.id ORDER BY at DESC LIMIT ?
                """, arguments: [Self.maxHistory], withCover: true)
        }) ?? []
        publishField(Self.fHistory, JSON.string(["tracks": refs.map(Self.refJSON)]), audience, onlyFor: onlyFor)
    }

    private static func refs(_ db: Database, sql: String, arguments: StatementArguments, withCover: Bool) throws -> [TrackRef] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { r in
            let id: String = r["id"]
            let names = try String.fetchAll(db, sql: """
                SELECT a.name FROM song_artist_map m JOIN artist a ON a.id = m.artistId WHERE m.songId = ? ORDER BY m.position
                """, arguments: [id])
            let cover: String? = r["thumbnailUrl"]
            let seconds: Int = r["duration"]
            let at: Int64? = r.hasColumn("at") ? r["at"] : nil
            return TrackRef(title: String((r["title"] as String).prefix(120)), artist: String(names.joined(separator: ", ").prefix(120)),
                            catalogId: FallbackIds.catalogId(of: id), mediaId: id.hasPrefix("local:") ? nil : id,
                            cover: withCover && (cover?.hasPrefix("http") ?? false) ? cover : nil,
                            durationMs: Int64(seconds) * 1000, at: at ?? 0)
        }
    }

    /// Лайки уходят заново, только если изменились (или раз в 3 дня, чтобы релеи их хранили).
    private func publishLikes(_ audience: Audience, onlyFor: String?) {
        let refs: [TrackRef] = (try? database.pool.read { db in
            try Self.refs(db, sql: "SELECT id, title, duration, thumbnailUrl FROM song WHERE liked = 1 ORDER BY likedDate DESC LIMIT ?",
                          arguments: [Self.maxLikes], withCover: true)
        }) ?? []
        guard !refs.isEmpty else { return }
        let total = (try? database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? 0 }) ?? refs.count
        let source = (store.string("likesSource") ?? "")
        let content = Self.packLikesFitting(SharedLikes(total: total, source: source.isEmpty ? nil : source, tracks: refs))
        // Стабильный между запусками хеш (hashValue в Swift случаен для каждого запуска).
        let digest = Secp256k1.sha256(Array(content.utf8))
        let hash = digest.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let fresh = store.int("likesHash") == hash && Self.nowMs() - Int64(store.value("likesAt").flatMap(Int.fromPref) ?? 0) < Self.likesRepublishMs
        if onlyFor == nil && fresh { return }
        publishField(Self.fLikes, content, audience, onlyFor: onlyFor)
        if onlyFor == nil {
            store.setLong(hash, for: "likesHash")
            store.setLong(Int(Self.nowMs()), for: "likesAt")
        }
    }

    // MARK: - Слушать вместе (ListenAlong)

    func startListenAlong(_ pubkey: String) {
        listeningTo = pubkey
        if liveSubs.isEmpty { openLive() }
        if let n = data[pubkey]?.now { onFriendNow?(n) }
    }

    func stopListenAlong() {
        listeningTo = nil
        if liveUsers == 0 { closeLive() }
    }

    // MARK: - JSON (CRITICAL §1.3)

    static func refJSON(_ r: TrackRef) -> JSONObject {
        var o: JSONObject = ["t": r.title, "a": r.artist]
        if let c = r.catalogId { o["c"] = c }
        if let m = r.mediaId { o["m"] = m }
        if let i = r.cover { o["i"] = i }
        if r.durationMs > 0 { o["d"] = r.durationMs }
        if r.at > 0 { o["at"] = r.at }
        return o
    }

    static func ref(from o: JSONObject) -> TrackRef {
        func opt(_ k: String) -> String? { o.str(k).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        return TrackRef(title: o.str("t") ?? "", artist: o.str("a") ?? "", catalogId: opt("c"), mediaId: opt("m"), cover: opt("i"),
                        durationMs: Int64(o.int("d") ?? 0), at: Int64(o.int("at") ?? 0))
    }

    static func nowJSON(_ n: NowPlaying) -> JSONObject {
        ["track": refJSON(n.track), "pos": n.positionMs, "playing": n.playing, "at": n.at, "along": n.listenAlong]
    }

    static func now(from o: JSONObject) -> NowPlaying? {
        guard let t = o.obj("track") else { return nil }
        return NowPlaying(track: ref(from: t), positionMs: Int64(o.int("pos") ?? 0), playing: o.bool("playing") ?? false,
                          at: Int64(o.int("at") ?? 0), listenAlong: o.bool("along") ?? true)
    }

    static func playlists(from a: [JSONObject]) -> [SharedPlaylist] {
        a.map { SharedPlaylist(name: $0.str("n") ?? "", total: $0.int("total") ?? 0, tracks: $0.objects("tracks").map(ref(from:))) }
    }

    static func stats(from o: JSONObject) -> Stats {
        Stats(weekMinutes: o.int("min") ?? 0, weekPlays: o.int("plays") ?? 0, likedCount: o.int("liked") ?? 0,
              topArtists: o.objects("top").map { ($0.str("n") ?? "", $0.int("c") ?? 0) })
    }

    static func privacyJSON(_ p: Privacy) -> JSONObject {
        ["now": p.nowPlaying.rawValue, "history": p.history.rawValue, "playlists": p.playlists.rawValue, "stats": p.stats.rawValue,
         "discoverable": p.discoverable, "along": p.listenAlong, "read": p.readReceipts]
    }

    static func privacy(from o: JSONObject) -> Privacy {
        func aud(_ k: String) -> Audience { o.str(k).flatMap(Audience.init(rawValue:)) ?? .FRIENDS }
        return Privacy(nowPlaying: aud("now"), history: aud("history"), playlists: aud("playlists"), stats: aud("stats"),
                       discoverable: o.bool("discoverable") ?? false, listenAlong: o.bool("along") ?? true, readReceipts: o.bool("read") ?? true)
    }

    // MARK: - Упаковка лайков: "gz1:" + base64(gzip(JSON))

    static func packLikesFitting(_ likes: SharedLikes) -> String {
        var count = likes.tracks.count
        while true {
            var l = likes
            l.tracks = Array(likes.tracks.prefix(count))
            let packed = packLikes(l)
            if packed.count <= maxLikesPacked || count <= 50 { return packed }
            count = count * 4 / 5
        }
    }

    /// Строки [название, артист, id каталога, секунды, индекс префикса обложки, хвост обложки, media id]; общие начала обложек — один раз.
    static func packLikes(_ likes: SharedLikes) -> String {
        var prefixes: [String] = []
        var prefixIndex: [String: Int] = [:]
        var rows: [[Any]] = []
        for t in likes.tracks {
            var index = -1
            var rest = ""
            if let cover = t.cover, let cut = cover.lastIndex(of: "/"), cut > cover.startIndex {
                let prefix = String(cover[...cut])
                if let i = prefixIndex[prefix] { index = i } else {
                    prefixes.append(prefix)
                    index = prefixes.count - 1
                    prefixIndex[prefix] = index
                }
                rest = String(cover[cover.index(after: cut)...])
            }
            rows.append([t.title, t.artist, t.catalogId ?? "", Int(t.durationMs / 1000), index, rest, t.mediaId ?? ""])
        }
        let json = JSON.string(["v": 1, "total": likes.total, "src": likes.source ?? "", "p": prefixes, "t": rows] as [String: Any])
        return likesPackedPrefix + Gzip.compress(Data(json.utf8)).base64EncodedString()
    }

    static func unpackLikes(_ content: String) -> SharedLikes? {
        var text = content
        if content.hasPrefix(likesPackedPrefix) {
            guard let data = Data(base64Encoded: String(content.dropFirst(likesPackedPrefix.count))),
                  let plain = Gzip.decompress(data), let s = String(data: plain, encoding: .utf8) else { return nil }
            text = s
        }
        guard let o = JSON.object(text) else { return nil }
        let prefixes = (o.arr("p") as? [String]) ?? []
        let tracks: [TrackRef] = (o.arr("t") ?? []).compactMap { row in
            guard let r = row as? [Any] else { return nil }
            func s(_ i: Int) -> String { i < r.count ? ((r[i] as? String) ?? "\(r[i])") : "" }
            func n(_ i: Int) -> Int { i < r.count ? ((r[i] as? NSNumber)?.intValue ?? Int(s(i)) ?? 0) : 0 }
            let idx = r.count > 4 ? n(4) : -1
            return TrackRef(title: s(0), artist: s(1), catalogId: s(2).isEmpty ? nil : s(2), mediaId: s(6).isEmpty ? nil : s(6),
                            cover: (idx >= 0 && idx < prefixes.count) ? prefixes[idx] + s(5) : nil, durationMs: Int64(n(3)) * 1000)
        }
        let src = o.str("src") ?? ""
        return SharedLikes(total: o.int("total") ?? tracks.count, source: src.isEmpty ? nil : src, tracks: tracks)
    }
}

/// gzip через zlib (Android: GZIPOutputStream / GZIPInputStream).
enum Gzip {
    static func compress(_ data: Data) -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        var out = Data(count: max(64, Int(deflateBound(&stream, uLong(data.count))) + 32))
        var input = [UInt8](data)
        let capacity = out.count
        let written: Int = out.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeMutableBufferPointer { inPtr in
                stream.next_in = inPtr.baseAddress
                stream.avail_in = uInt(inPtr.count)
                stream.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                _ = deflate(&stream, Z_FINISH)
                return capacity - Int(stream.avail_out)
            }
        }
        return out.prefix(written)
    }

    static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var input = [UInt8](data)
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var status: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    result.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                }
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? result : nil
    }
}
