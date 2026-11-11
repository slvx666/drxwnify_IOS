import SwiftUI
import UIKit

/// Экспорт плейлиста (DL-016, CRITICAL §4.2): CSV `Title,Artist,Album,YouTube Video ID` и M3U с `#EXTINF` и `#YTM:<id>`.
enum PlaylistExporter {
    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func csv(_ tracks: [Track]) -> String {
        var out = "Title,Artist,Album,YouTube Video ID\n"
        for t in tracks {
            out += quote(t.title) + "," + quote(t.artists.map { $0.name }.joined(separator: "; ")) + ","
                + quote(t.albumName ?? "") + "," + t.id + "\n"
        }
        return out
    }

    static func m3u(_ tracks: [Track]) -> String {
        var out = "#EXTM3U\n"
        for t in tracks {
            out += "#EXTINF:\(t.durationMs / 1000),\(t.artists.map { $0.name }.joined(separator: " - ")) - \(t.title)\n"
            out += "#YTM:\(t.id)\n"
        }
        return out
    }

    /// Пишет текст во временный файл с безопасным именем и возвращает его адрес.
    static func file(_ text: String, name: String, ext: String) -> URL? {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "Drxwnify" : safe) + "." + ext)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

extension DownloadManager {
    /// Копии скачанных файлов с понятными именами «Исполнитель - Название.ext» для «Поделиться» и «Файлов» (DL-004, DL-012).
    /// Теги и обложка внутрь файла пока не пишутся (KNOWN_ISSUES).
    func exportCopies(_ tracks: [Track]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for t in tracks {
            guard let src = fileURL(t.id) else { continue }
            let base = "\(t.artistNames) - \(t.title)".components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
            let dst = dir.appendingPathComponent(String(base.prefix(120)) + "." + src.pathExtension)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { out.append(dst) }
        }
        return out
    }
}

/// Сохранить файлы в «Файлы» (UIDocumentPicker в режиме экспорта, iOS 14+).
struct ExportToFiles: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
