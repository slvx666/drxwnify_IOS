import Foundation

/// Источники текстов (LYR-003, `lyrics/LyricsProviderRegistry.kt`): порядок и включение — настройки Android
/// `lyricsProviderOrder`, `enableBetterLyrics`, `enablePaxsenix`, `enableLrclib`, `enableKugou`, `enableLyricsPlus`.
enum LyricsProviders {
    static let all = ["BetterLyrics", "Paxsenix", "LrcLib", "KuGou", "LyricsPlus"]

    /// Ключ включения и значение по умолчанию (как `isEnabled` у провайдеров Android).
    static func enableKey(_ name: String) -> (PrefKey<Bool>, Bool)? {
        switch name {
        case "BetterLyrics": return (PK.enableBetterLyrics, true)
        case "Paxsenix": return (PK.enablePaxsenix, true)
        case "LrcLib": return (PK.enableLrclib, true)
        case "KuGou": return (PK.enableKugou, true)
        case "LyricsPlus": return (PK.enableLyricsPlus, false)
        default: return nil
        }
    }

    static func order(_ settings: TypedStore) -> [String] {
        let saved = (settings.get(PK.lyricsProviderOrder) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { all.contains($0) }
        return saved + all.filter { !saved.contains($0) }
    }

    static func isEnabled(_ name: String, _ settings: TypedStore) -> Bool {
        guard let (key, def) = enableKey(name) else { return false }
        return settings.get(key) ?? def
    }

    /// Название без «(feat. …)», «[Remastered]» (`LyricsUtils.cleanTitleForSearch`).
    static func cleanTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s*[(\[].*?[)\]]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Строки «synced by», «lyrics by» и подобные уходят (`LyricsUtils.filterLyricsCreditLines`).
    static func filterCredits(_ lyrics: String) -> String {
        lyrics.components(separatedBy: "\n").filter { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            while true {
                let before = t.count
                for p in [#"^\[\d\d:\d\d\.\d{2,3}\]"#, #"^\{agent:[^}]+\}"#, #"^\{bg\}"#, #"^\[bg:.*\]"#, #"^v\d+:"#] {
                    if let r = t.range(of: p, options: .regularExpression) { t.removeSubrange(r) }
                }
                t = t.trimmingCharacters(in: .whitespaces)
                if t.count >= before { break }
            }
            let l = t.lowercased()
            return !(l.hasPrefix("synced by") || l.hasPrefix("lyrics by") || l.hasPrefix("music by") || l.hasPrefix("arranged by"))
        }.joined(separator: "\n")
    }

    static func lrcTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        let cs = Int((total - floor(total)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    // MARK: - Сеть

    static func get(_ base: String, _ params: [(String, String)], headers: [String: String] = [:], timeout: TimeInterval = 15) async -> HTTP.Response? {
        var c = URLComponents(string: base)
        c?.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = c?.url, let r = try? await HTTP.get(url, headers: headers, timeout: timeout), r.isSuccess else { return nil }
        return r
    }

    // MARK: - BetterLyrics (`betterlyrics/BetterLyrics.kt`): TTML Apple Music → LRC

    static func betterLyrics(title: String, artist: String, durationSec: Int, album: String?) async -> String? {
        var params = [("s", title), ("a", artist)]
        if durationSec > 0 { params.append(("d", String(durationSec))) }
        if let a = album, !a.isEmpty { params.append(("al", a)) }
        guard let r = await get("https://lyrics-api.boidu.dev/getLyrics", params,
                                headers: ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", "Accept": "application/json"]),
              let ttml = JSON.object(r.data)?.str("ttml"), !ttml.isEmpty else { return nil }
        let lrc = TTML.toLRC(ttml)
        return lrc.isEmpty ? nil : lrc
    }

    // MARK: - LyricsPlus (`lyrics/LyricsPlusProvider.kt`)

    static func lyricsPlus(title: String, artist: String, durationMs: Int, album: String?) async -> String? {
        for base in ["https://lyricsplus.binimum.org", "https://lyricsplus.atomix.one", "https://lyricsplus-seven.vercel.app"] {
            var params = [("title", title), ("artist", artist), ("duration", String(durationMs > 0 ? durationMs / 1000 : -1))]
            if let a = album, !a.isEmpty { params.append(("album", a)) }
            params.append(("source", "apple,lyricsplus,musixmatch,spotify,musixmatch-word"))
            guard let r = await get(base + "/v2/lyrics/get", params), let o = JSON.object(r.data) else { continue }
            let lines = o.objects("lyrics").compactMap { l -> String? in
                guard let text = l.str("text"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                let ms = Double(l.int("time") ?? 0)
                return "[\(lrcTime(ms / 1000))]\(text)"
            }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        return nil
    }

    // MARK: - Paxsenix (`paxsenix/Paxsenix.kt`): только пословные тексты Apple Music, остальное отдаёт другим

    static func paxsenix(title: String, artist: String, durationSec: Int, album: String?) async -> String? {
        let cleanTitle = cleanTitle(title)
        let cleanArtist = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?.trimmingCharacters(in: .whitespaces) ?? artist
        var queries = ["\(cleanTitle) \(cleanArtist)", cleanTitle]
        if let a = album, !a.isEmpty { queries.append("\(cleanTitle) \(cleanArtist) \(a)") }
        var scored: [(String, Double)] = []
        for q in queries where scored.isEmpty {
            guard let r = await get("https://lyrics.paxsenix.org/apple-music/search", [("q", q)]),
                  let list = JSON.array(r.data) as? [JSONObject] else { continue }
            scored = score(list, title: title, artist: cleanArtist, durationMs: durationSec * 1000)
        }
        for (id, _) in scored.prefix(3) {
            if let lrc = await paxsenixLyrics(id), lrc.contains("<") && lrc.contains(">") { return lrc }
        }
        return nil
    }

    private static func score(_ results: [JSONObject], title: String, artist: String, durationMs: Int) -> [(String, Double)] {
        let cleanup = #"\s*\(.*?\)|\s*\[.*?\]"#
        let wantedTitle = title.replacingOccurrences(of: cleanup, with: "", options: .regularExpression).lowercased().trimmingCharacters(in: .whitespaces)
        let wantedArtist = artist.lowercased()
        let targetMixed = title.lowercased().contains("mixed"), targetRemix = title.lowercased().contains("remix")
        return results.compactMap { r -> (String, Double)? in
            guard let id = r.str("id") else { return nil }
            var s = 0.0
            let name = r.str("trackName") ?? r.str("songName") ?? ""
            let by = (r.str("artistName") ?? "").lowercased()
            if let d = r.int("duration"), durationMs > 0 {
                let diff = abs(d - durationMs)
                s += diff <= 2000 ? 100 : diff <= 5000 ? 50 : diff <= 10000 ? 10 : -50
            }
            let cleaned = name.replacingOccurrences(of: cleanup, with: "", options: .regularExpression).lowercased().trimmingCharacters(in: .whitespaces)
            if cleaned == wantedTitle { s += 80 } else if cleaned.contains(wantedTitle) || wantedTitle.contains(cleaned) { s += 40 }
            if name.lowercased().contains("mixed") && !targetMixed { s -= 60 }
            if name.lowercased().contains("remix") && !targetRemix { s -= 40 }
            if by.contains(wantedArtist) { s += 50 } else if wantedArtist.split(separator: " ").contains(where: { $0.count > 2 && by.contains($0) }) { s += 25 }
            return (id, s)
        }.sorted { $0.1 > $1.1 }.filter { $0.1 > 0 }
    }

    private static func paxsenixLyrics(_ id: String) async -> String? {
        guard let r = await get("https://lyrics.paxsenix.org/apple-music/lyrics", [("id", id)]), let o = JSON.object(r.data) else { return nil }
        if let ttml = o.str("ttmlContent"), !ttml.isEmpty {
            let lrc = TTML.toLRC(ttml)
            if !lrc.isEmpty { return lrc }
        }
        for key in ["elrcMultiPerson", "elrc", "plain"] {
            if let v = o.str(key), !v.isEmpty { return v }
        }
        return nil
    }
}

/// Разбор TTML Apple Music в LRC (`betterlyrics/TTMLParser.kt`, упрощённо): строки `<p begin>` с пословными
/// метками `<mm:ss.xx>` из `<span begin>`; фоновые голоса — отдельной строкой в скобках.
final class TTML: NSObject, XMLParserDelegate {
    private struct Word { var text: String; var start: Double? }
    private struct Line { var start: Double; var words: [Word]; var background = false }

    private var lines: [Line] = []
    private var current: Line?
    private var background: Line?
    private var pendingBackground: [Line] = []
    private var spanStarts: [Double?] = []
    private var spanRoles: [String?] = []
    private var offset = 0.0

    static func toLRC(_ ttml: String) -> String {
        let t = TTML()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = t
        guard parser.parse() else { return "" }
        return t.render()
    }

    /// «12.34», «1:02.5», «00:01:02.500», «12.3s».
    static func seconds(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("ms") { return Double(s.dropLast(2)).map { $0 / 1000 } }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "audio":
            offset = Double(attributes["lyricOffset"] ?? "") ?? 0
        case "p":
            current = Line(start: (Self.seconds(attributes["begin"]) ?? 0) + offset, words: [])
        case "span":
            let role = attributes["role"] ?? attributes.first { $0.key.hasSuffix("role") }?.value
            spanRoles.append(role)
            spanStarts.append(Self.seconds(attributes["begin"]).map { $0 + offset })
            if role == "x-bg", background == nil, let c = current {
                background = Line(start: spanStarts.last.flatMap { $0 } ?? c.start, words: [], background: true)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        let inBackground = spanRoles.contains("x-bg")
        let start = spanStarts.last.flatMap { $0 }
        var word = Word(text: string, start: start)
        // Пробел между словами-спанами принадлежит предыдущему слову.
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if inBackground { appendSpace(&background) } else { appendSpace(&current) }
            return
        }
        if inBackground {
            if let last = background?.words.last, last.start == start, start != nil { word.start = nil }
            background?.words.append(word)
        } else {
            if let last = current?.words.last, last.start == start, start != nil { word.start = nil }
            current?.words.append(word)
        }
    }

    private func appendSpace(_ line: inout Line?) {
        guard var l = line, !l.words.isEmpty else { return }
        if !(l.words[l.words.count - 1].text.hasSuffix(" ")) { l.words[l.words.count - 1].text += " " }
        line = l
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "span":
            let role = spanRoles.popLast() ?? nil
            _ = spanStarts.popLast()
            if role == "x-bg", let b = background {
                pendingBackground.append(b)
                background = nil
            }
        case "p":
            if let c = current, !c.words.isEmpty { lines.append(c) }
            lines.append(contentsOf: pendingBackground.filter { !$0.words.isEmpty })
            pendingBackground = []
            current = nil
        default: break
        }
    }

    private func render() -> String {
        lines.filter { !$0.words.isEmpty }.map { line in
            let words = line.words.map { w -> String in
                if let s = w.start { return "<\(LyricsProviders.lrcTime(s))>" + w.text }
                return w.text
            }.joined()
            let body = words.trimmingCharacters(in: .whitespaces)
            return "[\(LyricsProviders.lrcTime(line.start))]" + (line.background ? "{bg}" : "") + body
        }.joined(separator: "\n")
    }
}
