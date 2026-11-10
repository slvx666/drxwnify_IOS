import Foundation

/// Строка из Localizable.strings. Имена ключей совпадают с именами строк Android (`strings.xml`).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
