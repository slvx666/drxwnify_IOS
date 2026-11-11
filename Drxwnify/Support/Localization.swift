import Foundation

/// Язык приложения (Android 1.5.2, настройка `appLanguage`): `ru`, `en` или системный.
enum AppLanguage {
    static let systemDefault = "SYSTEM_DEFAULT"
    private static let key = "appLanguage"

    /// Выбранный код или nil — как в системе.
    static var code: String? {
        let v = UserDefaults.standard.string(forKey: key) ?? systemDefault
        return v == systemDefault || v.isEmpty ? nil : v
    }

    private static var cached: (String?, Bundle)?

    static var bundle: Bundle {
        let c = code
        if let hit = cached, hit.0 == c { return hit.1 }
        let b = c.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? Bundle.main
        cached = (c, b)
        return b
    }

    static var current: String { code ?? Bundle.main.preferredLocalizations.first ?? "ru" }
}

/// Строка интерфейса.
/// `Localizable.strings` сгенерирован из строк Android (те же имена ключей),
/// `IOS.strings` — строки, которых на Android нет.
func L(_ key: String) -> String {
    let bundle = AppLanguage.bundle
    let own = bundle.localizedString(forKey: key, value: "\u{1}", table: "IOS")
    if own != "\u{1}" { return own }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Множественная форма: ключи `имя.one/.few/.many/.other` (из `<plurals>` Android).
func LPlural(_ key: String, _ count: Int) -> String {
    let lang = AppLanguage.current
    let form: String
    if lang.hasPrefix("ru") {
        let n10 = abs(count) % 10
        let n100 = abs(count) % 100
        if n10 == 1 && n100 != 11 {
            form = "one"
        } else if (2...4).contains(n10) && !(12...14).contains(n100) {
            form = "few"
        } else {
            form = "many"
        }
    } else {
        form = count == 1 ? "one" : "other"
    }
    var format = L("\(key).\(form)")
    if format == "\(key).\(form)" { format = L("\(key).other") }
    return String(format: format, count)
}
