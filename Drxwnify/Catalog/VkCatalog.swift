import Foundation

/// Id каталога ВК (Android 2.3.0 `VkCatalog`):
/// - трек `src:VK:owner_audio[_key]` — тот же id, что у трека ВК из поиска источников;
/// - альбом или плейлист `vk_owner_id[_key]` (в ВК и то и другое — «плейлисты»);
/// - исполнитель `vkar_<id>`; «Моя музыка» — `vk_liked`.
enum VkIds {
    static let trackPrefix = "src:VK:"
    static let playlistPrefix = "vk_"
    static let artistPrefix = "vkar_"
    static let likedSongsId = "vk_liked"

    static func isVk(_ id: String?) -> Bool {
        guard let id = id else { return false }
        return id.hasPrefix(trackPrefix) || id.hasPrefix(artistPrefix) || id.hasPrefix(playlistPrefix)
    }

    static func track(_ fullId: String) -> String { trackPrefix + fullId }
    static func fullId(_ trackId: String?) -> String? {
        guard let t = trackId, t.hasPrefix(trackPrefix) else { return nil }
        return String(t.dropFirst(trackPrefix.count))
    }

    static func playlist(ownerId: Int, id: Int, accessKey: String?) -> String {
        playlistPrefix + ([String(ownerId), String(id)] + (accessKey.map { [$0] } ?? [])).joined(separator: "_")
    }

    static func playlist(_ p: VkProvider.VkPlaylist) -> String { playlist(ownerId: p.ownerId, id: p.playlistId, accessKey: p.accessKey) }

    struct Address {
        var ownerId: Int
        var id: Int
        var accessKey: String?
    }

    static func parsePlaylist(_ id: String) -> Address? {
        guard id.hasPrefix(playlistPrefix), id != likedSongsId else { return nil }
        let parts = id.dropFirst(playlistPrefix.count).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let owner = Int(parts[0]), let pid = Int(parts[1]) else { return nil }
        return Address(ownerId: owner, id: pid, accessKey: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }

    static func artist(_ raw: String) -> String { artistPrefix + raw }
    static func rawArtist(_ id: String) -> String? { id.hasPrefix(artistPrefix) ? String(id.dropFirst(artistPrefix.count)) : nil }
}

/// ВК Музыка как каталог наравне со Spotify и Яндексом: те же модели, поэтому страницы альбома, исполнителя,
/// плейлиста, «Моей музыки» и медиатеки работают для ВК так же. Альбомы и страницы исполнителей — только у официальных релизов.
final class VkCatalog {
    let vk: VkProvider

    init(vk: VkProvider) { self.vk = vk }

    /// Свой аккаунт ВК (не общий тестовый): медиатека и запись работают.
    var isAuthenticated: Bool { vk.hasOwnAccount }

    // MARK: - Модели

    private static func images(_ url: String?) -> [SpotifyImage] {
        url.map { [SpotifyImage(url: $0, height: 600, width: 600)] } ?? []
    }

    static func trackOf(_ a: VkProvider.Audio) -> SpotifyTrack {
        let artists: [SpotifySimpleArtist] = a.artistRefs.isEmpty
            ? a.artist.components(separatedBy: ", ").filter { !$0.isEmpty }.map { SpotifySimpleArtist(id: nil, name: $0) }
            : a.artistRefs.map { SpotifySimpleArtist(id: $0.id.map(VkIds.artist), name: $0.name) }
        let album: SpotifySimpleAlbum? = a.album.map { al in
            SpotifySimpleAlbum(id: VkIds.playlist(ownerId: al.ownerId, id: al.id, accessKey: al.accessKey), name: al.title,
                               images: images(al.cover ?? a.thumb), albumType: "album")
        } ?? a.thumb.map { SpotifySimpleAlbum(id: "", name: "", images: images($0)) }
        return SpotifyTrack(id: VkIds.track(a.fullId), name: a.title, artists: artists, album: album,
                            durationMs: a.durationSec * 1000, uri: "vk:audio:\(a.fullId)")
    }

    private static func albumType(_ p: VkProvider.VkPlaylist) -> String {
        if !p.isAlbum { return "playlist" }
        if (1...3).contains(p.count) { return "single" }
        if (4...6).contains(p.count) { return "ep" }
        return "album"
    }

    static func albumOf(_ p: VkProvider.VkPlaylist, tracks: [VkProvider.Audio]) -> SpotifyAlbum {
        let names = p.subtitle.components(separatedBy: ", ").filter { !$0.isEmpty }
        // Исполнители альбома с id ВК — из его треков, если там те же люди.
        var known: [VkProvider.ArtistRef] = []
        for r in tracks.flatMap({ $0.artistRefs }) where r.id != nil && !known.contains(where: { $0.name.lowercased() == r.name.lowercased() }) {
            known.append(r)
        }
        var artists = names.map { n in SpotifySimpleArtist(id: known.first { $0.name.lowercased() == n.lowercased() }?.id.map(VkIds.artist), name: n) }
        if artists.isEmpty { artists = known.prefix(1).map { SpotifySimpleArtist(id: $0.id.map(VkIds.artist), name: $0.name) } }
        return SpotifyAlbum(id: VkIds.playlist(p), name: p.title, albumType: albumType(p), artists: artists, images: images(p.thumb),
                            releaseDate: p.year.map(String.init), totalTracks: tracks.isEmpty ? p.count : tracks.count,
                            tracks: tracks.map { var t = $0; if t.thumb == nil { t.thumb = p.thumb }; return trackOf(t) },
                            uri: "vk:playlist:\(p.ownerId)_\(p.playlistId)")
    }

    static func playlistOf(_ p: VkProvider.VkPlaylist) -> SpotifyPlaylist {
        SpotifyPlaylist(id: VkIds.playlist(p), name: p.title, images: images(p.thumb),
                        owner: SpotifyPlaylistOwner(id: String(p.ownerId), displayName: p.subtitle.isEmpty ? nil : p.subtitle),
                        totalTracks: p.count, uri: "vk:playlist:\(p.ownerId)_\(p.playlistId)")
    }

    // MARK: - Сущности

    private var playlistMemo: [String: VkProvider.VkPlaylist] = [:]
    private let lock = NSLock()

    private func remember(_ list: [VkProvider.VkPlaylist]) {
        lock.lock(); defer { lock.unlock() }
        for p in list { playlistMemo["\(p.ownerId)_\(p.playlistId)"] = p }
    }

    private func playlistAt(_ a: VkIds.Address) async throws -> VkProvider.VkPlaylist {
        lock.lock(); let known = playlistMemo["\(a.ownerId)_\(a.id)"]; lock.unlock()
        if let p = known { return p }
        guard let p = try await vk.playlistById(ownerId: a.ownerId, playlistId: a.id, accessKey: a.accessKey) else {
            throw VkProvider.ApiError(code: 404, message: "VK album not found")
        }
        remember([p])
        return p
    }

    func album(_ id: String) async throws -> SpotifyAlbum {
        guard let a = VkIds.parsePlaylist(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK album") }
        let p = try await playlistAt(a)
        let tracks = try await vk.playlistAudios(ownerId: a.ownerId, playlistId: a.id, accessKey: a.accessKey ?? p.accessKey)
        return Self.albumOf(p, tracks: tracks)
    }

    func playlist(_ id: String) async throws -> SpotifyPlaylist {
        if id == VkIds.likedSongsId {
            return SpotifyPlaylist(id: id, name: L("vk_liked_songs"), totalTracks: (try? await myTracks().count) ?? 0)
        }
        guard let a = VkIds.parsePlaylist(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK playlist") }
        return Self.playlistOf(try await playlistAt(a))
    }

    private var pages: [String: (Date, [VkProvider.Audio])] = [:]

    func playlistTracks(_ id: String, limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        let all: [VkProvider.Audio]
        if id == VkIds.likedSongsId {
            all = try await myTracks()
        } else {
            guard let a = VkIds.parsePlaylist(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK playlist") }
            lock.lock(); let cached = pages[id]; lock.unlock()
            if let c = cached, offset > 0 || Date().timeIntervalSince(c.0) < Self.ttl {
                all = c.1
            } else {
                all = try await vk.playlistAudios(ownerId: a.ownerId, playlistId: a.id, accessKey: a.accessKey)
                lock.lock(); pages[id] = (Date(), all); lock.unlock()
            }
        }
        let page = all.dropFirst(offset).prefix(limit).map { SpotifyPlaylistTrack(addedAt: nil, track: Self.trackOf($0), uid: nil) }
        return SpotifyPaging(items: Array(page), total: all.count, limit: limit, offset: offset)
    }

    func track(_ id: String) async throws -> SpotifyTrack {
        guard let full = VkIds.fullId(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK track") }
        guard let a = try await trackInfo(full) else { throw VkProvider.ApiError(code: 404, message: "VK track not found") }
        return Self.trackOf(a)
    }

    /// Альбом и исполнители трека ВК по полному id: из памяти, иначе один запрос.
    func trackInfo(_ fullId: String) async throws -> VkProvider.Audio? {
        if let a = VkTrackStore.shared.get(fullId) { return a }
        return try await vk.audiosById([fullId]).first
    }

    func artist(_ id: String) async throws -> SpotifyArtist {
        guard let raw = VkIds.rawArtist(id), let a = try await vk.artist(raw) else { throw VkProvider.ApiError(code: 404, message: "VK artist not found") }
        return SpotifyArtist(id: id, name: a.name, images: Self.images(a.photo), uri: "vk:artist:\(raw)")
    }

    func artistTopTracks(_ id: String) async throws -> [SpotifyTrack] {
        guard let raw = VkIds.rawArtist(id) else { return [] }
        return try await vk.artistAudios(raw, count: 30).map(Self.trackOf)
    }

    func artistDiscography(_ id: String) async throws -> SpotifyArtistDiscography {
        guard let raw = VkIds.rawArtist(id) else { return SpotifyArtistDiscography() }
        let lists = try await vk.artistAlbums(raw)
        remember(lists)
        let all = lists.map { Self.albumOf($0, tracks: []) }.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        return SpotifyArtistDiscography(albums: all.filter { $0.albumType == "album" },
                                        singles: all.filter { $0.albumType == "single" || $0.albumType == "ep" },
                                        compilations: [], latest: all.first)
    }

    // MARK: - Медиатека

    private static let ttl: TimeInterval = 5 * 60
    private var myTracksCache: (Date, [VkProvider.Audio])?
    private var myPlaylistsCache: (Date, [VkProvider.VkPlaylist])?

    func myTracks(force: Bool = false) async throws -> [VkProvider.Audio] {
        lock.lock(); let c = myTracksCache; lock.unlock()
        if !force, let c = c, Date().timeIntervalSince(c.0) < Self.ttl { return c.1 }
        let list = try await vk.myAudios()
        lock.lock(); myTracksCache = (Date(), list); lock.unlock()
        return list
    }

    private func myPlaylists() async throws -> [VkProvider.VkPlaylist] {
        lock.lock(); let c = myPlaylistsCache; lock.unlock()
        if let c = c, Date().timeIntervalSince(c.0) < Self.ttl { return c.1 }
        let list = try await vk.myPlaylists()
        remember(list)
        lock.lock(); myPlaylistsCache = (Date(), list); lock.unlock()
        return list
    }

    func invalidate() {
        lock.lock()
        myTracksCache = nil
        myPlaylistsCache = nil
        pages.removeAll()
        lock.unlock()
    }

    func likedSongs(limit: Int, offset: Int) async throws -> SpotifyPaging<SpotifyPlaylistTrack> {
        try await playlistTracks(VkIds.likedSongsId, limit: limit, offset: offset)
    }

    /// Вся медиатека ВК строками: «Моя музыка» первой, затем альбомы (по числу треков) и плейлисты.
    func library() async throws -> [SpotifyLibraryEntry] {
        let lists = try await myPlaylists()
        let count = (try? await myTracks().count) ?? 0
        classifyInBackground(lists)
        var out = [SpotifyLibraryEntry(kind: .likedSongs, id: VkIds.likedSongsId, uri: "vk:collection", name: L("vk_liked_songs"),
                                       pinned: true, totalCount: count)]
        var albums: [SpotifyLibraryEntry] = []
        for p in lists {
            // Плейлист человека, который на деле запись одного исполнителя, — тоже альбом (вид решён по трекам).
            let album = VkKinds.known(p) ?? p.isAlbum
            if album {
                albums.append(SpotifyLibraryEntry(kind: .album, id: VkIds.playlist(p), uri: "vk:album:\(p.ownerId)_\(p.playlistId)", name: p.title,
                                                  creator: p.subtitle.isEmpty ? nil : p.subtitle, imageUrl: p.thumb, albumType: Self.albumType(p),
                                                  totalCount: p.count, year: p.year))
            } else {
                out.append(SpotifyLibraryEntry(kind: .playlist, id: VkIds.playlist(p), uri: "vk:playlist:\(p.ownerId)_\(p.playlistId)", name: p.title,
                                               creator: p.subtitle.isEmpty ? nil : p.subtitle, imageUrl: p.thumb, totalCount: p.count))
            }
        }
        // Альбомы ВК — по числу треков (Android 2.3.0).
        return out + albums.enumerated().sorted { a, b in
            a.element.totalCount != b.element.totalCount ? a.element.totalCount > b.element.totalCount : a.offset < b.offset
        }.map { $0.element }
    }

    private var classifying = false

    /// Плейлисты людей, вид которых ещё неизвестен, смотрятся по трекам в фоне (один исполнитель на всех — альбом):
    /// не больше 200, пауза 400 мс (Android `classifyInBackground`).
    private func classifyInBackground(_ lists: [VkProvider.VkPlaylist]) {
        lock.lock()
        if classifying { lock.unlock(); return }
        let unknown = lists.filter { $0.ownerId > 0 && VkKinds.known($0) == nil }
        if unknown.isEmpty { lock.unlock(); return }
        classifying = true
        lock.unlock()
        let vk = self.vk
        Task.detached(priority: .background) { [weak self] in
            var learned = 0
            for p in unknown.prefix(200) {
                if let tracks = try? await vk.playlistAudios(ownerId: p.ownerId, playlistId: p.playlistId, accessKey: p.accessKey), tracks.count >= 2 {
                    let artists = Set(tracks.map { ($0.artistRefs.first?.name ?? $0.artist).lowercased() })
                    VkKinds.set(p, album: artists.count == 1)
                    learned += 1
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard let self = self else { return }
            self.lock.lock()
            self.classifying = false
            if learned > 0 { self.myPlaylistsCache = nil }
            self.lock.unlock()
        }
    }

    // MARK: - Лайки и сохранённые альбомы

    /// Лайк в ВК — трек в «Моей музыке». Копия в своём списке запоминается, чтобы снять лайк.
    func saveTrack(_ id: String) async throws {
        guard let full = VkIds.fullId(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK track") }
        guard isAuthenticated else { throw VkProvider.ApiError(code: 401, message: "VK account not linked") }
        let copy = try await vk.addAudio(full)
        if copy != 0, let me = await vk.myId() { VkSavedCopies.set(full, "\(me)_\(copy)") }
        lock.lock(); myTracksCache = nil; lock.unlock()
    }

    func removeTrack(_ id: String) async throws {
        guard let full = VkIds.fullId(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK track") }
        guard isAuthenticated else { throw VkProvider.ApiError(code: 401, message: "VK account not linked") }
        let me = await vk.myId() ?? ""
        let base = full.split(separator: "_").prefix(2).map(String.init)
        // Свой трек — сам по себе; чужой — по запомненной копии, иначе ищем в «Моей музыке» по названию.
        var address: [String]? = base.first == me ? base : VkSavedCopies.get(full)?.split(separator: "_").map(String.init)
        if address == nil, let target = VkTrackStore.shared.get(full) {
            if let mine = try? await myTracks().first(where: { $0.title.lowercased() == target.title.lowercased() && $0.artist.lowercased() == target.artist.lowercased() }) {
                address = mine.baseId.split(separator: "_").map(String.init)
            }
        }
        guard let a = address, a.count >= 2 else { return }
        try await vk.deleteAudio(ownerId: a[0], audioId: a[1])
        VkSavedCopies.set(full, nil)
        lock.lock(); myTracksCache = nil; lock.unlock()
    }

    func isTrackSaved(_ id: String) async -> Bool {
        guard let full = VkIds.fullId(id), let mine = try? await myTracks() else { return false }
        let base = full.split(separator: "_").prefix(2).joined(separator: "_")
        if mine.contains(where: { $0.baseId == base }) { return true }
        guard let copy = VkSavedCopies.get(full) else { return false }
        return mine.contains { $0.baseId == copy }
    }

    func isAlbumSaved(_ id: String) async throws -> Bool {
        guard let a = VkIds.parsePlaylist(id) else { return false }
        return try await myPlaylists().contains { $0.ownerId == a.ownerId && $0.playlistId == a.id }
    }

    func setAlbumSaved(_ id: String, saved: Bool) async throws {
        guard let a = VkIds.parsePlaylist(id) else { throw VkProvider.ApiError(code: 400, message: "Not a VK album") }
        guard isAuthenticated else { throw VkProvider.ApiError(code: 401, message: "VK account not linked") }
        let mine = try await myPlaylists().first { $0.ownerId == a.ownerId && $0.playlistId == a.id }
        if saved {
            if mine == nil { try await vk.followPlaylist(try await playlistAt(a)) }
        } else if let m = mine {
            try await vk.deletePlaylist(ownerId: m.libraryOwnerId ?? m.ownerId, playlistId: m.libraryId ?? m.playlistId)
        }
        lock.lock(); myPlaylistsCache = nil; lock.unlock()
    }

    // MARK: - «К альбому» и «К исполнителю» у любого трека ВК (Android 2.3.0, этап 3)

    struct Release {
        var albumId: String?
        var albumName: String?
        var artistId: String?
        var artistName: String?
    }

    /// Альбом и исполнитель трека ВК. У загрузки пользователя их нет — ищется официальный релиз того же трека.
    func release(trackId: String, title: String, artist: String, durationMs: Int) async -> Release? {
        func of(_ a: VkProvider.Audio) -> Release? {
            let al = a.album
            let ar = a.artistRefs.first { $0.id != nil }
            guard al != nil || ar != nil else { return nil }
            return Release(albumId: al.map { VkIds.playlist(ownerId: $0.ownerId, id: $0.id, accessKey: $0.accessKey) }, albumName: al?.title,
                           artistId: ar?.id.map(VkIds.artist), artistName: ar?.name)
        }
        if let full = VkIds.fullId(trackId), let info = try? await trackInfo(full), let r = of(info) { return r }
        guard let found = try? await vk.searchAudios([artist, title].filter { !$0.isEmpty }.joined(separator: " "), count: 20) else { return nil }
        let ranked = FuzzyTrackMatch.ranked(
            artist: artist.isEmpty ? nil : artist, title: title, durationSec: durationMs > 0 ? durationMs / 1000 : nil,
            candidates: found.filter { $0.album != nil || $0.artistRefs.contains { $0.id != nil } }.map {
                FuzzyTrackMatch.Candidate(id: $0.fullId, title: $0.title, artists: $0.artistRefs.map { $0.name } + [$0.artist],
                                          durationSec: $0.durationSec > 0 ? $0.durationSec : nil)
            })
        guard let best = ranked.first, let a = found.first(where: { $0.fullId == best.id }) else { return nil }
        return of(a)
    }

    // MARK: - Поиск и рекомендации

    func search(_ query: String, limit: Int) async throws -> SpotifySearchResult {
        async let tracks = vk.searchAudios(query, count: limit)
        async let lists = vk.searchPlaylists(query, count: 40)
        let t = (try? await tracks) ?? []
        let l = (try? await lists) ?? []
        remember(l)
        var seen = Set<String>()
        let q = query.trimmingCharacters(in: .whitespaces)
        let artists = t.flatMap { $0.artistRefs }.filter { r in
            guard let id = r.id else { return false }
            return r.name.range(of: q, options: .caseInsensitive) != nil && seen.insert(id).inserted
        }.prefix(limit).map { SpotifyArtist(id: VkIds.artist($0.id ?? ""), name: $0.name) }
        return SpotifySearchResult(tracks: t.map(Self.trackOf), tracksTotal: t.count,
                                   albums: l.filter { $0.isAlbum }.map { Self.albumOf($0, tracks: []) },
                                   artists: Array(artists),
                                   playlists: l.filter { !$0.isAlbum }.map(Self.playlistOf))
    }

    private var recommendationsCache: (Date, [SpotifyTrack])?

    /// «Для вас» ВК, свежие несколько часов.
    func recommendations() async -> [SpotifyTrack] {
        lock.lock(); let c = recommendationsCache; lock.unlock()
        if let c = c, Date().timeIntervalSince(c.0) < 3 * 3600 { return c.1 }
        let list = ((try? await vk.recommendationAudios(count: 100)) ?? []).map(Self.trackOf)
        if !list.isEmpty { lock.lock(); recommendationsCache = (Date(), list); lock.unlock() }
        return list
    }

    // MARK: - Запись плейлистов

    func createPlaylist(_ title: String) async throws -> String {
        guard isAuthenticated, let p = try await vk.createPlaylist(title) else { throw VkProvider.ApiError(code: 0, message: "VK refused to create the playlist") }
        lock.lock(); myPlaylistsCache = nil; lock.unlock()
        return VkIds.playlist(p)
    }

    func addToPlaylist(_ playlistId: String, trackIds: [String]) async throws {
        guard let a = VkIds.parsePlaylist(playlistId) else { throw VkProvider.ApiError(code: 400, message: "Not a VK playlist") }
        let ids = trackIds.compactMap { VkIds.fullId($0)?.split(separator: "_").prefix(2).joined(separator: "_") }
        try await vk.addToPlaylist(ownerId: a.ownerId, playlistId: a.id, audioIds: ids)
        lock.lock(); pages[playlistId] = nil; lock.unlock()
    }
}

/// Вид плейлистов людей, решённый по трекам (альбом или плейлист), хранится на телефоне.
enum VkKinds {
    private static let key = "vk_playlist_kind"
    static func known(_ p: VkProvider.VkPlaylist) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?["\(p.ownerId)_\(p.playlistId)"]
    }
    static func set(_ p: VkProvider.VkPlaylist, album: Bool) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        d["\(p.ownerId)_\(p.playlistId)"] = album
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Адрес копии лайкнутого чужого трека в «Моей музыке» (нужен, чтобы снять лайк).
enum VkSavedCopies {
    private static let key = "vk_saved_tracks"
    static func get(_ fullId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[fullId.split(separator: "_").prefix(2).joined(separator: "_")]
    }
    static func set(_ fullId: String, _ copy: String?) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[fullId.split(separator: "_").prefix(2).joined(separator: "_")] = copy
        UserDefaults.standard.set(d, forKey: key)
    }
}
