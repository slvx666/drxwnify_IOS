import Foundation

/// Романизация текстов (LYR-0xx, `settings/content/romanization`): японский, корейский, китайский и по желанию кириллица —
/// встроенной транслитерацией iOS (`ToLatin`), без сети. Строка романизируется, только если в ней есть буквы этого письма.
enum Romanizer {
    static let keys = ["japanese", "korean", "chinese", "cyrillic"]
    private static let defaults = UserDefaults.standard

    static func isOn(_ lang: String) -> Bool {
        (defaults.object(forKey: "ios_romanize_" + lang) as? Bool) ?? (lang != "cyrillic")
    }

    static func set(_ lang: String, _ on: Bool) { defaults.set(on, forKey: "ios_romanize_" + lang) }

    static var asMain: Bool {
        get { UserDefaults(suiteName: "ds.settings")?.bool(forKey: "lyricsRomanizeAsMain") ?? false }
    }

    private static func has(_ text: String, _ ranges: [ClosedRange<UInt32>]) -> Bool {
        text.unicodeScalars.contains { s in ranges.contains { $0.contains(s.value) } }
    }

    static func romanize(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let kana = has(text, [0x3040...0x30FF])
        let han = has(text, [0x4E00...0x9FFF])
        let hangul = has(text, [0xAC00...0xD7AF, 0x1100...0x11FF])
        let cyrillic = has(text, [0x0400...0x04FF])
        let wanted = (kana && isOn("japanese")) || (hangul && isOn("korean")) || (han && !kana && isOn("chinese"))
            || (han && kana && isOn("japanese")) || (cyrillic && isOn("cyrillic"))
        guard wanted else { return nil }
        let m = NSMutableString(string: text)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
        let out = (m as String).trimmingCharacters(in: .whitespaces)
        return out == text ? nil : out
    }
}
