import Foundation
import Combine

/// Единая точка зависимостей приложения. Передаётся через `EnvironmentObject`.
final class AppEnvironment: ObservableObject {
    let prefs: Prefs
    let database: AppDatabase
    let backup: BackupManager
    let player: PlayerController

    init() {
        prefs = Prefs()
        database = Self.openDatabase()
        backup = BackupManager(prefs: prefs, database: database)
        player = PlayerController()
    }

    /// Открывает базу; повреждённый файл откладывает в сторону и создаёт новый.
    private static func openDatabase() -> AppDatabase {
        if let db = try? AppDatabase() { return db }
        let url = AppDatabase.defaultURL
        let fm = FileManager.default
        let broken = url.deletingLastPathComponent().appendingPathComponent("song.broken.db")
        try? fm.removeItem(at: broken)
        try? fm.moveItem(at: url, to: broken)
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        do {
            return try AppDatabase()
        } catch {
            fatalError("Не удалось создать базу: \(error)")
        }
    }
}
