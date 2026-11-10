import Foundation

/// Чтение и запись файлов Android SharedPreferences (`shared_prefs/<имя>.xml`):
///
///     <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
///     <map>
///         <string name="k">текст</string>
///         <boolean name="b" value="true" />
///         <int name="i" value="1" /> <long name="l" value="2" /> <float name="f" value="1.5" />
///         <set name="s"><string>a</string><string>b</string></set>
///     </map>
enum AndroidPrefsXML {
    static func decode(_ data: Data) -> [String: PrefValue] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    static func encode(_ values: [String: PrefValue]) -> Data {
        var s = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n"
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            let name = escape(key)
            switch value {
            case .bool(let v): s += "    <boolean name=\"\(name)\" value=\"\(v)\" />\n"
            case .int(let v): s += "    <int name=\"\(name)\" value=\"\(v)\" />\n"
            case .long(let v): s += "    <long name=\"\(name)\" value=\"\(v)\" />\n"
            case .float(let v): s += "    <float name=\"\(name)\" value=\"\(v)\" />\n"
            // В SharedPreferences нет double и bytes; пишем так, чтобы Android хотя бы прочитал файл.
            case .double(let v): s += "    <float name=\"\(name)\" value=\"\(Float(v))\" />\n"
            case .bytes(let v): s += "    <string name=\"\(name)\">\(v.base64EncodedString())</string>\n"
            case .string(let v): s += "    <string name=\"\(name)\">\(escape(v))</string>\n"
            case .stringSet(let v):
                s += "    <set name=\"\(name)\">\n"
                for item in v { s += "        <string>\(escape(item))</string>\n" }
                s += "    </set>\n"
            }
        }
        s += "</map>\n"
        return Data(s.utf8)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default:
                // Управляющие символы в XML 1.0 запрещены; Android их тоже не пишет.
                if ch.value < 0x20 { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var values: [String: PrefValue] = [:]
        private var depth = 0
        private var currentName: String?
        private var text = ""
        private var collecting = false
        private var setName: String?
        private var setItems: [String] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            if depth == 2 {
                let name = attributes["name"]
                let raw = attributes["value"]
                switch element {
                case "string":
                    currentName = name; text = ""; collecting = true
                case "set":
                    setName = name; setItems = []
                case "boolean":
                    if let name = name, let raw = raw { values[name] = .bool(raw == "true") }
                case "int":
                    if let name = name, let raw = raw, let v = Int32(raw) { values[name] = .int(v) }
                case "long":
                    if let name = name, let raw = raw, let v = Int64(raw) { values[name] = .long(v) }
                case "float":
                    if let name = name, let raw = raw, let v = Float(raw) { values[name] = .float(v) }
                default:
                    break
                }
            } else if depth == 3, element == "string", setName != nil {
                text = ""; collecting = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if depth == 3, element == "string", setName != nil {
                setItems.append(text); collecting = false
            } else if depth == 2 {
                if element == "string", let name = currentName {
                    values[name] = .string(text)
                    currentName = nil; collecting = false
                } else if element == "set", let name = setName {
                    values[name] = .stringSet(setItems)
                    setName = nil
                }
            }
            depth -= 1
        }
    }
}
