import Foundation
import Combine
import GRDB

enum DatabaseError2: Error, LocalizedError {
    case schemaTooOld(Int), notSongDatabase, schemaResourceMissing

    var errorDescription: String? {
        switch self {
        case .schemaTooOld(let v):
            return "База из копии слишком старая (схема \(v), нужна \(AppDatabase.schemaVersion)). Обнови Drxwnify на Android и создай копию заново."
        case .notSongDatabase: return "Файл song.db повреждён или это не база Drxwnify"
        case .schemaResourceMissing: return "В приложении нет файла схемы базы"
        }
    }
}

/// Основная база `song.db`. Схема совпадает с Room-базой Android версии 40,
/// поэтому файл из Android-копии подключается как есть.
final class AppDatabase: ObservableObject {
    static let schemaVersion = 40
    static let fileName = "song.db"

    /// Меняется при подмене файла базы (восстановление из копии): экраны перечитывают данные.
    @Published private(set) var generation = 0

    private(set) var pool: DatabasePool
    let url: URL

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    init(url: URL = AppDatabase.defaultURL) throws {
        self.url = url
        self.pool = try Self.open(url)
    }

    private static func open(_ url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        try pool.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            let hasSong = try db.tableExists("song")
            if version == 0 && !hasSong {
                try createSchema(db)
            } else if !hasSong {
                throw DatabaseError2.notSongDatabase
            } else if version < schemaVersion {
                throw DatabaseError2.schemaTooOld(version)
            }
        }
        return pool
    }

    private static func createSchema(_ db: Database) throws {
        guard let sqlURL = Bundle.main.url(forResource: "song_v40", withExtension: "sql"),
              let sql = try? String(contentsOf: sqlURL, encoding: .utf8) else {
            throw DatabaseError2.schemaResourceMissing
        }
        try db.execute(sql: sql)
        try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    /// Версия схемы и число строк по таблицам в произвольном файле базы (для проверки копии).
    static func inspect(_ url: URL) throws -> (version: Int, counts: [String: Int]) {
        // Копия из Android в режиме WAL, а -shm рядом нет: открываем на запись (это временный файл)
        // и сразу переводим в обычный журнал, иначе чтение может отказать.
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        if (try? queue.inDatabase { try String.fetchOne($0, sql: "PRAGMA journal_mode") }) == "wal" {
            try? queue.inDatabase { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE") }
        }
        return try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard try db.tableExists("song") else { throw DatabaseError2.notSongDatabase }
            var counts: [String: Int] = [:]
            for table in ["song", "artist", "album", "playlist", "playlist_song_map", "event", "lyrics"] {
                if try db.tableExists(table) {
                    counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
                }
            }
            return (version, counts)
        }
    }

    func counts() -> [String: Int] {
        (try? pool.read { db -> [String: Int] in
            var out: [String: Int] = [:]
            for table in ["song", "artist", "album", "playlist", "event"] {
                out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
            out["liked"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE liked = 1") ?? 0
            return out
        }) ?? [:]
    }

    /// Сливает WAL в основной файл (перед созданием копии).
    func checkpoint() throws {
        try pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Подменяет файл базы файлом из копии. Старая база удаляется.
    func replace(withFileAt newURL: URL) throws {
        let info = try Self.inspect(newURL)
        if info.version < Self.schemaVersion { throw DatabaseError2.schemaTooOld(info.version) }

        let fm = FileManager.default
        let backupURL = url.appendingPathExtension("old")
        try? pool.close()
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: url, to: backupURL)
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        do {
            try fm.moveItem(at: newURL, to: url)
            pool = try Self.open(url)
            try? fm.removeItem(at: backupURL)
        } catch {
            // Не получилось — возвращаем прежнюю базу.
            try? fm.removeItem(at: url)
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
            try? fm.moveItem(at: backupURL, to: url)
            pool = try Self.open(url)
            throw error
        }
        DispatchQueue.main.async { self.generation += 1 }
    }
}
