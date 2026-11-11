import Foundation

/// Проверка совпадения трека (CRITICAL §2.3) — перенос `utils/FuzzyTrackMatch.kt`.
enum FuzzyTrackMatch {
    struct Candidate {
        var id: String
        var title: String
        var artists: [String]
        var durationSec: Int?
    }

    struct Scored {
        var id: String
        var score: Double
        var titleScore: Double
        var artistScore: Double
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let featInTitle = rx("[(\\[]\\s*(?:feat\\.?|ft\\.?|featuring|with)\\s+([^)\\]]+)[)\\]]")
    private static let featTail = rx("\\s+(?:feat\\.?|ft\\.?|featuring)\\s+(.+)$")
    private static let brackets = rx("[(\\[{][^)\\]}]*[)\\]}]")
    private static let yearTail = rx("\\s*[-–—(]?\\s*(?:19|20)\\d{2}(?:\\s*(?:version|remaster(?:ed)?|mix|edition))?\\s*\\)?\\s*$")
    private static let numberHead = rx("^\\s*(?:[ivxlc]{1,6}\\.|\\d{1,3}\\s*[.)\\-–]\\s*)\\s*")
    private static let dashSuffix = rx("\\s+[-–—]\\s+.*$")
    private static let artistSplit = rx("\\s*(?:,|&|/|\\band\\b|\\bx\\b|\\bvs\\.?|\\bfeat\\.?|\\bft\\.?|\\bwith\\b)\\s*")
    private static let foreign = rx("\\b(cover|karaoke|remix|rmx|nightcore|sped up|slowed|reverb|8d|instrumental|acoustic|live|кавер|ремикс|минус|караоке)\\b")
    private static let spaces = rx("\\s+")

    static let maxDurationOffS = 30

    // MARK: - Регулярные выражения

    private static func replace(_ re: NSRegularExpression, in s: String, with r: String) -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: r)
    }

    private static func firstGroup(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func allMatches(_ re: NSRegularExpression, in s: String) -> Set<String> {
        var out = Set<String>()
        for m in re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range, in: s) { out.insert(String(s[r])) }
        }
        return out
    }

    private static func split(_ re: NSRegularExpression, _ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }

    // MARK: - Разбор

    static func splitArtists(_ s: String) -> [String] {
        split(artistSplit, s).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Гости из названия: "Song (feat. A & B)" → [A, B].
    static func featuredArtists(_ title: String) -> [String] {
        guard let raw = firstGroup(featInTitle, in: title) ?? firstGroup(featTail, in: title) else { return [] }
        return splitArtists(raw)
    }

    /// Варианты написания названия, от буквального к самому короткому.
    static func titleVariants(_ title: String) -> [String] {
        let noFeat = replace(featTail, in: replace(featInTitle, in: title, with: " "), with: " ")
        let bracketless = replace(brackets, in: noFeat, with: " ")
        let noYear = replace(yearTail, in: bracketless.trimmingCharacters(in: .whitespaces), with: "")
        let noNumber = replace(numberHead, in: noYear, with: "")
        let beforeDash = replace(dashSuffix, in: noNumber, with: "")
        var out: [String] = []
        for v in [title, noFeat, bracketless, noYear, noNumber, beforeDash] {
            let clean = replace(spaces, in: v, with: " ").trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty && !out.contains(clean) { out.append(clean) }
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        let folded = s.lowercased().decomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        var out = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            if u.properties.generalCategory == .nonspacingMark { continue }
            if CharacterSet.alphanumerics.contains(u) {
                out.append(u == "ё" ? "е" : u)
            } else {
                out.append(" ")
            }
        }
        var r = replace(spaces, in: String(out), with: " ").trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("the ") { r.removeFirst(4) }
        return r
    }

    /// 0…1: лучшее из пересечения биграмм и расстояния правки; вхождение целым словом = 0.9.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 1 }
        let shorter = x.count <= y.count ? x : y
        let longer = x.count <= y.count ? y : x
        let paddedLong: String = " " + String(longer) + " "
        let paddedShort: String = " " + String(shorter) + " "
        let isContained: Bool = shorter.count >= 4 && paddedLong.contains(paddedShort)
        let contained: Double = isContained ? 0.9 : 0.0
        let distance: Double = Double(levenshtein(x, y))
        let lev: Double = 1.0 - distance / Double(longer.count)
        let d: Double = dice(x, y)
        return max(contained, max(d, lev))
    }

    private static func dice(_ a: [Character], _ b: [Character]) -> Double {
        if a.count < 2 || b.count < 2 { return 0 }
        func bigrams(_ s: [Character]) -> [String: Int] {
            var d: [String: Int] = [:]
            for i in 0..<(s.count - 1) { d[String(s[i...i + 1]), default: 0] += 1 }
            return d
        }
        let ba = bigrams(a), bb = bigrams(b)
        var common = 0
        for (k, n) in ba { common += min(n, bb[k] ?? 0) }
        let total: Int = a.count - 1 + b.count - 1
        return 2.0 * Double(common) / Double(total)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let ins: Int = cur[j - 1] + 1
                let del: Int = prev[j] + 1
                let sub: Int = prev[j - 1] + cost
                cur[j] = min(min(ins, del), sub)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Оценка

    /// Все прошедшие проверку кандидаты, лучший первым. `maxDurationGap` ужесточает допуск по длине.
    static func ranked(artist: String?, title: String, durationSec: Int?, candidates: [Candidate],
                       maxDurationGap: Int = maxDurationOffS) -> [Scored] {
        let wantedTitles = titleVariants(title)
        let wantedArtists = (artist.map(splitArtists) ?? []) + featuredArtists(title)
        let ownForeign = allMatches(foreign, in: title.lowercased())
        var out: [Scored] = []
        for c in candidates {
            if !allMatches(foreign, in: c.title.lowercased()).subtracting(ownForeign).isEmpty { continue }
            var off: Int?
            if let d = durationSec, d > 0, let cd = c.durationSec, cd > 0 { off = abs(d - cd) }
            if let off = off, off > maxDurationGap { continue }
            let candTitles = titleVariants(c.title)
            var titleScore = 0.0
            for w in wantedTitles { for t in candTitles { titleScore = max(titleScore, similarity(w, t)) } }
            var artistScore = 0.0
            for w in wantedArtists { for a in c.artists { artistScore = max(artistScore, similarity(w, a)) } }
            let closeLength: Bool = (off ?? Int.max) <= 3
            let accepted: Bool
            if wantedArtists.isEmpty {
                accepted = titleScore >= 0.97 && closeLength
            } else if artistScore >= 0.85 {
                accepted = titleScore >= 0.8 || (titleScore >= 0.7 && closeLength)
            } else if artistScore >= 0.7 {
                accepted = titleScore >= 0.95 && (off ?? 0) <= 5
            } else {
                accepted = false
            }
            if !accepted { continue }
            let bonus: Double = closeLength ? 0.05 : 0.0
            let score: Double = titleScore * 0.6 + artistScore * 0.4 + bonus
            out.append(Scored(id: c.id, score: score, titleScore: titleScore, artistScore: artistScore))
        }
        return out.sorted { $0.score > $1.score }
    }

    static func best(artist: String?, title: String, durationSec: Int?, candidates: [Candidate]) -> Scored? {
        ranked(artist: artist, title: title, durationSec: durationSec, candidates: candidates).first
    }
}
