import Foundation

/// Хеши persisted-запросов GQL Spotify (INT-006).
/// Порядок: удалённый реестр / кэш → зашитые значения (всегда есть).
/// Порт `SpotifyHashProvider.kt` и `utils/SpotifyHashSync.kt`.
final class SpotifyHashes {
    struct Entry {
        let hash: String
        let previousHash: String?
    }

    private static let remoteURL = URL(string: "https://francescograzioso.github.io/Meld/spotify-gql-hashes.json")!

    private static let defaults: [String: String] = [
        "profileAttributes": "53bcb064f6cd18c23f752bc324a791194d20df612d8e1239c735144ab0399ced",
        "libraryV3": "973e511ca44261fda7eebac8b653155e7caee3675abb4fb110cc1b8c78b091c3",
        "fetchPlaylist": "346811f856fb0b7e4f6c59f8ebea78dd081c6e2fb01b77c954b26259d5fc6763",
        "fetchLibraryTracks": "087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240",
        "searchDesktop": "4801118d4a100f756e833d33984436a3899cff359c532f8fd3aaf174b60b3b49",
        "queryArtistOverview": "5b9e64f43843fa3a9b6a98543600299b0a2cbbbccfdcdcef2402eb9c1017ca4c",
        "getAlbum": "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
        "queryWhatsNewFeed": "3b53dede3c6054e8b7c962dd280eb6761c5d1c82b06b039f4110d76a62b4966b",
        "addToPlaylist": "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990",
        "removeFromPlaylist": "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990",
        "moveItemsInPlaylist": "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990",
        "editPlaylistAttributes": "35a1a9ce3a2f4f8c32ee0e24c63c2069c6613c0a0b7e56d0e40dabe69a0b4f80",
        "addToLibrary": "7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d",
        "removeFromLibrary": "7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d",
        "home": "23e37f2e58d82d567f27080101d36609009d8c3676457b1086cb0acc55b72a5d",
        // Топы профиля (Android 2.3.0): в общий реестр не входит, при смене перечитывается из веб-плеера.
        "userTopContent": "61b7353d3625780022dbc63d459eb64cd609e7e5e2a820f9160d65030efe2e15",
    ]

    private let settings: TypedStore
    private let lock = NSLock()
    private var hashes: [String: Entry]
    private var fetching: Task<Void, Never>?

    init(settings: TypedStore) {
        self.settings = settings
        hashes = Self.defaults.mapValues { Entry(hash: $0, previousHash: nil) }
        // Кэш прошлого запуска — до первого запроса к Spotify.
        if let cached = settings.get(PK.spotifyGqlHashesJson) {
            apply(Self.parse(cached))
        }
        for op in ["userTopContent"] {
            if let h = UserDefaults.standard.string(forKey: "gql_override_" + op) { hashes[op] = Entry(hash: h, previousHash: hashes[op]?.hash) }
        }
    }

    /// Хеш, найденный в коде веб-плеера (для операций, которых нет в реестре).
    func override(_ operation: String, _ hash: String) {
        lock.lock(); defer { lock.unlock() }
        hashes[operation] = Entry(hash: hash, previousHash: hashes[operation]?.hash)
        UserDefaults.standard.set(hash, forKey: "gql_override_" + operation)
    }

    func hash(_ operation: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashes[operation]?.hash
    }

    func previousHash(_ operation: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashes[operation]?.previousHash
    }

    /// Обновляет только известные операции, как на Android.
    private func apply(_ remote: [String: Entry]) {
        lock.lock(); defer { lock.unlock() }
        for (op, entry) in remote where hashes[op] != nil {
            hashes[op] = entry
        }
    }

    private static func parse(_ raw: String) -> [String: Entry] {
        guard let operations = JSON.object(raw)?.obj("operations") else { return [:] }
        var out: [String: Entry] = [:]
        for (op, value) in operations {
            guard let o = value as? JSONObject, let hash = o.str("hash") else { continue }
            out[op] = Entry(hash: hash, previousHash: o.str("previous_hash"))
        }
        return out
    }

    /// Запрос реестра. Вызывается при каждом запуске и когда Spotify отверг хеш.
    func sync() async {
        lock.lock()
        if let running = fetching {
            lock.unlock()
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.fetching = nil
                self.lock.unlock()
            }
            guard let response = try? await HTTP.get(Self.remoteURL, headers: ["Accept": "application/json"], timeout: 10),
                  response.status == 200 else { return }
            let body = response.text
            let parsed = Self.parse(body)
            if parsed.isEmpty { return }
            self.apply(parsed)
            self.settings.set(PK.spotifyGqlHashesJson, body)
            self.settings.set(PK.spotifyGqlHashesLastFetch, Int(Date().timeIntervalSince1970 * 1000))
        }
        fetching = task
        lock.unlock()
        await task.value
    }
}
