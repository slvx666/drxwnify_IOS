import Foundation

/// Концерт в «Афише» (`concerts/Concerts.kt`): Петербург и Ленобласть.
struct Concert: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    /// Начало, мс с 1970.
    var start: Int64
    var venue: String
    var locality: String
    /// Самый дешёвый билет, ₽; 0 — бесплатно, nil — не указано.
    var price: Int?
    var genres: [String]
    var imageUrl: String?
    var url: String
    var sources: [String]
    var altUrl: String?
    var timeKnown: Bool

    var date: Date { Date(timeIntervalSince1970: Double(start) / 1000) }
    var isFree: Bool { price == 0 }
}

/// Источники афиши, слияние, кэш на 4 часа, переключатель (SharedPreferences `concerts`, `enabled`, по умолчанию вкл.).
/// Перенесены concertinfo.ru и kovelt.ru; Telegram-афиши и оповещения — позже.
actor Concerts {
    static let shared = Concerts()
    private static let ttl: TimeInterval = 4 * 3600
    private var list: [Concert] = []
    private var updatedAt = Date.distantPast

    static var isEnabled: Bool {
        (UserDefaults(suiteName: "sp.concerts")?.object(forKey: "enabled") as? Bool) ?? true
    }

    private static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("concerts_cache.json")
    }

    /// Кэш сразу, свежее — если кэш старше 4 часов (или `force`).
    func load(force: Bool = false) async -> [Concert] {
        if list.isEmpty, let data = try? Data(contentsOf: Self.cacheFile),
           let saved = try? JSONDecoder().decode([Concert].self, from: data) {
            list = saved
            updatedAt = (try? Self.cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        if !force, !list.isEmpty, Date().timeIntervalSince(updatedAt) < Self.ttl { return upcoming(list) }
        async let ci = Self.concertinfo()
        async let kv = Self.kovelt()
        let (a, b) = await (ci, kv)
        if a == nil && b == nil { return upcoming(list) }
        let merged = Self.merge((a ?? []) + (b ?? []))
        list = merged
        updatedAt = Date()
        if let data = try? JSONEncoder().encode(merged) { try? data.write(to: Self.cacheFile, options: .atomic) }
        return upcoming(merged)
    }

    private func upcoming(_ l: [Concert]) -> [Concert] {
        let from = Int64((Date().timeIntervalSince1970 - 3 * 3600) * 1000)
        return l.filter { $0.start >= from }.sorted { $0.start < $1.start }
    }

    // MARK: - Сеть

    private static func get(_ url: String) async -> String? {
        guard let u = URL(string: url), let r = try? await HTTP.get(u, headers: ["User-Agent": "Mozilla/5.0 (iPhone) Drxwnify"], timeout: 30),
              r.isSuccess else { return nil }
        return r.text
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: concertinfo.ru

    private static let ciGenres: [Int: String] = [
        31: "Acoustic", 7: "Alternative", 41: "Ambient", 28: "Avant-garde", 9: "Black Metal", 42: "Blues", 45: "Country", 50: "Cover",
        27: "Dark Metal", 40: "Darkwave", 13: "Death Metal", 58: "Deathcore", 16: "Doom Metal", 30: "EBM", 12: "Electronic", 56: "Emocore",
        39: "Experimental", 6: "Folk", 48: "Funk", 49: "Garage Rock", 34: "Glam", 5: "Gothic", 20: "Grindcore", 47: "Groove Metal",
        36: "Grunge", 60: "Hard Rock", 24: "Hardcore", 14: "Heavy Metal", 37: "Indie", 25: "Industrial", 17: "Jazz", 15: "Melodic Metal",
        4: "Metal", 57: "Metalcore", 53: "Neofolk", 29: "Neue Deutsche Härte", 35: "Noise", 46: "Nu Metal", 32: "Pop", 11: "Post",
        52: "Power Metal", 33: "Progressive", 3: "Punk", 51: "Rap", 22: "Reggae", 2: "Rock", 44: "Rock'n'roll", 19: "Rockabilly",
        21: "Ska", 26: "Sludge Metal", 43: "Stoner", 23: "Surf", 8: "Symphonic", 10: "Thrash Metal", 38: "Trip-Hop", 54: "Мюзикл",
        1: "Русский рок", 55: "Шансон",
    ]

    private static func concertinfo() async -> [Concert]? {
        let base = "https://concertinfo.ru"
        guard let html = await get(base + "/filter/?city=1") else { return nil }
        let cities = ["1": "Санкт-Петербург", "5": "Ленинградская область"]
        var out: [Concert] = []
        for block in html.components(separatedBy: "<div class=\"ev-line search_line ").dropFirst() {
            let cls = (block.components(separatedBy: "\"").first ?? "").split(separator: " ").map(String.init)
            guard let city = cls.first(where: { $0.count > 1 && $0.hasPrefix("c") && $0.dropFirst().allSatisfy(\.isNumber) })?.dropFirst(),
                  let cityName = cities[String(city)] else { continue }
            if let st = first(#"eventStatus" href="https://schema\.org/(\w+)""#, in: block), st.lowercased().contains("cancel") { continue }
            guard let begin = first(#"data-begin="(\d+)""#, in: block).flatMap({ Int64($0) }),
                  let id = first(#"class="ev-name[^"]*" href="/gig/(\d+)/""#, in: block),
                  let name = first(#"class="ev-name[^>]*><span[^>]*>([^<]*)</span>"#, in: block) else { continue }
            let genres = cls.filter { $0.count > 1 && $0.hasPrefix("t") && $0.dropFirst().allSatisfy(\.isNumber) }
                .compactMap { Int($0.dropFirst()).flatMap { ciGenres[$0] } }
            guard let place = first(#"<span class="search_cell">([^<]*)</span></span></span></span>"#, in: block).map(decode)
                    ?? first(#"<span class="ev-venue" title="([^"]*)""#, in: block).map({ decode(String($0.split(separator: ",").first ?? "")) }) else { continue }
            var rub = first(#"itemprop="price" content="(\d+)""#, in: block).flatMap { Int($0) }
            if rub == nil, let t = first(#"<span class="ev-price">([^<]*)</span>"#, in: block) {
                rub = t.lowercased().contains("беспл") ? 0 : Int(t.filter(\.isNumber).prefix(6))
            }
            let img = first(#"class="thumb" href="[^"]*"[^>]*><img src="([^"]*)""#, in: block).map { $0.hasPrefix("http") ? $0 : base + $0 }
            out.append(Concert(id: "ci" + id, title: decode(name), start: begin * 1000, venue: place, locality: cityName, price: rub,
                               genres: genres, imageUrl: img, url: "\(base)/gig/\(id)/", sources: ["Concertinfo"], altUrl: nil, timeKnown: true))
        }
        return out
    }

    // MARK: kovelt.ru

    private static func kovelt() async -> [Concert]? {
        let base = "https://kovelt.ru"
        let musicKinds: Set<String> = ["Концерт", "Фестиваль", "Вечеринка"]
        let noKind: Set<String> = ["", "Событие"]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var out: [Concert] = []
        var seen = Set<String>()
        var ok = 0
        let days: [String] = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: Date()).map(f.string) }
        let pages: [String?] = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, d) in days.enumerated() { group.addTask { (i, await get("\(base)/d/\(d)/")) } }
            var res = [String?](repeating: nil, count: days.count)
            for await (i, p) in group { res[i] = p }
            return res
        }
        guard let article = try? NSRegularExpression(pattern: #"<article class="ev" ([^>]*)>(.*?)</article>"#, options: [.dotMatchesLineSeparators]),
              let attr = try? NSRegularExpression(pattern: #"data-(\w+)="([^"]*)""#) else { return nil }
        for page in pages {
            guard let page = page else { continue }
            ok += 1
            for m in article.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
                guard let ar = Range(m.range(at: 1), in: page), let br = Range(m.range(at: 2), in: page) else { continue }
                let attrs = String(page[ar]), body = String(page[br])
                var a: [String: String] = [:]
                for am in attr.matches(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) {
                    if let k = Range(am.range(at: 1), in: attrs), let v = Range(am.range(at: 2), in: attrs) { a[String(attrs[k])] = String(attrs[v]) }
                }
                let kind = decode(a["k"] ?? "")
                let genres = (a["g"] ?? "").split(separator: "|").map { decode(String($0)) }.filter { !$0.isEmpty }
                guard musicKinds.contains(kind) || (noKind.contains(kind) && !genres.isEmpty),
                      let ds = a["d"], let day = f.date(from: ds), let id = a["id"],
                      let link = first(#"<h3 class="t"><a href="(/e/[^"]+)">"#, in: body),
                      let title = first(#"<h3 class="t"><a href="/e/[^"]+">([^<]*)</a>"#, in: body),
                      let place = first(#"<a class="vn" href="[^"]*">([^<]*)</a>"#, in: body).map(decode), !place.isEmpty,
                      seen.insert(id).inserted else { continue }
                var start = day.addingTimeInterval(12 * 3600)
                var known = false
                if let hh = first(#"<div class="tm">(\d{1,2}):(\d{2})</div>"#, in: body).flatMap({ Int($0) }),
                   let mm = first(#"<div class="tm">\d{1,2}:(\d{2})</div>"#, in: body).flatMap({ Int($0) }) {
                    start = day.addingTimeInterval(Double(min(23, hh) * 3600 + min(59, mm) * 60))
                    known = true
                }
                out.append(Concert(id: "kv" + id, title: decode(title), start: Int64(start.timeIntervalSince1970 * 1000), venue: place,
                                   locality: "Санкт-Петербург", price: a["free"] == "1" ? 0 : nil,
                                   genres: genres.map { $0.prefix(1).uppercased() + $0.dropFirst() }, imageUrl: nil, url: base + link,
                                   sources: ["Ковельт"], altUrl: first(#"class="src">[^<]*<a href="(https?://[^"]+)""#, in: body), timeKnown: known))
            }
        }
        return ok == 0 ? nil : out
    }

    // MARK: - Слияние: один концерт — один день, одна площадка, один хедлайнер

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber }
    }

    static func merge(_ all: [Concert]) -> [Concert] {
        var out: [Concert] = []
        let cal = Calendar.current
        func lead(_ c: Concert) -> String { norm(String(c.title.split(whereSeparator: { ",/+(".contains($0) }).first ?? "")) }
        for c in all.sorted(by: { $0.start < $1.start }) {
            let l = lead(c), v = norm(c.venue)
            if let i = out.firstIndex(where: { o in
                cal.isDate(o.date, inSameDayAs: c.date) && norm(o.venue) == v && l.count > 2 &&
                    (lead(o) == l || norm(o.title).contains(l) || norm(c.title).contains(lead(o)))
            }) {
                var o = out[i]
                o.price = o.price ?? c.price
                o.genres = Array(NSOrderedSet(array: o.genres + c.genres)) as? [String] ?? o.genres
                o.imageUrl = o.imageUrl ?? c.imageUrl
                o.sources = Array(Set(o.sources + c.sources)).sorted()
                o.altUrl = o.altUrl ?? c.altUrl ?? (c.url != o.url ? c.url : nil)
                if !o.timeKnown && c.timeKnown { o.start = c.start; o.timeKnown = true }
                out[i] = o
            } else {
                out.append(c)
            }
        }
        return out
    }
}
