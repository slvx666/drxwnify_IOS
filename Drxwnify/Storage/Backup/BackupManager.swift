import Foundation

/// Резервная копия в формате Android (SYS-200, SYS-201; `spec/CRITICAL.md` §4.1).
///
/// ZIP с записями `settings.preferences_pb`, `song.db`, `shared_prefs/<имя>.xml`, `covers/<файл>`.
final class BackupManager {
    static let settingsEntry = "settings.preferences_pb"
    static let databaseEntry = "song.db"
    static let prefsPrefix = "shared_prefs/"
    static let coversPrefix = "covers/"

    struct Summary {
        var schemaVersion = 0
        var counts: [String: Int] = [:]
        var settingsCount = 0
        var sharedFiles: [String] = []
        var covers = 0
        var accounts: [String] = []
        var hasFriendsKey = false
    }

    enum BackupError: Error, LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: return "В файле нет данных Drxwnify: это не резервная копия"
            }
        }
    }

    private let prefs: Prefs
    private let database: AppDatabase

    init(prefs: Prefs, database: AppDatabase) {
        self.prefs = prefs
        self.database = database
    }

    /// Папка обложек своих плейлистов (Android: `filesDir/playlist_covers`).
    static var coversDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlist_covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isSafe(_ name: String) -> Bool {
        !name.contains("..") && !name.contains("/") && !name.isEmpty
    }

    // MARK: Восстановление

    /// Заменяет данные приложения содержимым копии. Вызывать не с главного потока.
    /// - Parameter clearAuthData: убрать сессию YouTube из копии (как на Android).
    @discardableResult
    func restore(from url: URL, clearAuthData: Bool = false) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let zip = try ZipReader(url: url)
        var summary = Summary()

        // 1. Сначала всё разбираем и проверяем, потом применяем: неполного восстановления быть не должно.
        var settings: [String: PrefValue]?
        var shared: [String: [String: PrefValue]] = [:]
        var covers: [(String, ZipReader.Entry)] = []
        var tempDB: URL?

        for entry in zip.entries where !entry.isDirectory {
            if entry.name == Self.settingsEntry {
                settings = try PreferencesProto.decode(try zip.data(for: entry))
            } else if entry.name == Self.databaseEntry {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).db")
                try zip.extract(entry, to: tmp)
                tempDB = tmp
            } else if entry.name.hasPrefix(Self.coversPrefix) {
                let name = String(entry.name.dropFirst(Self.coversPrefix.count))
                if Self.isSafe(name) { covers.append((name, entry)) }
            } else if entry.name.hasPrefix(Self.prefsPrefix) {
                var name = String(entry.name.dropFirst(Self.prefsPrefix.count))
                guard Self.isSafe(name), name.hasSuffix(".xml") else { continue }
                name.removeLast(4)
                shared[name] = AndroidPrefsXML.decode(try zip.data(for: entry))
            }
        }
        guard settings != nil || tempDB != nil || !shared.isEmpty || !covers.isEmpty else { throw BackupError.empty }

        // 2. База (может отказать из-за старой схемы — тогда остальное не трогаем).
        if let tempDB = tempDB {
            defer { try? FileManager.default.removeItem(at: tempDB) }
            let info = try AppDatabase.inspect(tempDB)
            summary.schemaVersion = info.version
            summary.counts = info.counts
            try database.replace(withFileAt: tempDB)
        }

        // 3. Настройки.
        if var settings = settings {
            if clearAuthData {
                for key in ["innerTubeCookie", "visitorData", "dataSyncId"] { settings[key] = nil }
            }
            prefs.settings.replaceAll(settings)
            summary.settingsCount = settings.count
        }

        // 4. SharedPreferences.
        if !shared.isEmpty {
            prefs.removeAllShared()
            for (name, values) in shared { prefs.shared(name).replaceAll(values) }
            summary.sharedFiles = shared.keys.sorted()
        }

        // 5. Обложки.
        for (name, entry) in covers {
            try zip.extract(entry, to: Self.coversDirectory.appendingPathComponent(name))
        }
        summary.covers = covers.count

        fillAccounts(&summary)
        return summary
    }

    // MARK: Создание

    /// Пишет копию во временный файл и возвращает его адрес. Вызывать не с главного потока.
    func create() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drxwnify_\(formatter.string(from: Date())).backup")

        let zip = try ZipWriter(url: url)
        try zip.add(name: Self.settingsEntry, data: PreferencesProto.encode(prefs.settings.allValues()))
        try database.checkpoint()
        try zip.add(name: Self.databaseEntry, fileAt: database.url)
        for name in prefs.sharedFileNames {
            let values = prefs.shared(name).allValues()
            if values.isEmpty { continue }
            try zip.add(name: Self.prefsPrefix + name + ".xml", data: AndroidPrefsXML.encode(values))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.coversDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !file.hasDirectoryPath {
            try zip.add(name: Self.coversPrefix + file.lastPathComponent, fileAt: file)
        }
        try zip.finish()
        return url
    }

    // MARK: Сводка

    /// Что сейчас лежит в приложении.
    func currentSummary() -> Summary {
        var summary = Summary()
        summary.schemaVersion = AppDatabase.schemaVersion
        summary.counts = database.counts()
        summary.settingsCount = prefs.settings.allValues().count
        summary.sharedFiles = prefs.sharedFileNames.filter { !prefs.shared($0).isEmpty }
        summary.covers = ((try? FileManager.default.contentsOfDirectory(atPath: Self.coversDirectory.path)) ?? []).count
        fillAccounts(&summary)
        return summary
    }

    private func fillAccounts(_ summary: inout Summary) {
        var accounts: [String] = []
        let s = prefs.settings
        if !(s.get(PK.spotifySpDc) ?? "").isEmpty { accounts.append("Spotify") }
        if !(s.get(PK.yandexAccessToken) ?? "").isEmpty { accounts.append("Яндекс Музыка") }
        if !(s.get(PK.vkAccessToken) ?? "").isEmpty { accounts.append("VK") }
        if !(s.get(PK.innerTubeCookie) ?? "").isEmpty { accounts.append("YouTube") }
        if !(s.get(PK.lastfmSession) ?? "").isEmpty { accounts.append("Last.fm") }
        summary.accounts = accounts
        summary.hasFriendsKey = !(prefs.shared("friends").string("sk") ?? "").isEmpty
    }
}
