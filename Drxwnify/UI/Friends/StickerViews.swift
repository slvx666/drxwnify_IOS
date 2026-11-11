import SwiftUI
import ImageIO

/// Стикеры чата (2.2.1, 2.2.5) — перенос `friends/Stickers.kt`: картинки и `stickers.json` из Android-ассетов,
/// в тексте сообщения стикер — токен `\u{E000}id\u{E001}` (совместимо с Android).
enum StickerStore {
    struct Sticker: Identifiable, Hashable {
        let id: String
        let code: String
        let width: Int
        let height: Int
        let animated: Bool
        var aspect: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 1 }
        var url: URL? { Bundle.main.url(forResource: id, withExtension: "webp") }
    }

    enum Part: Hashable {
        case text(String)
        case image(String)
    }

    static let all: [Sticker] = {
        guard let url = Bundle.main.url(forResource: "stickers", withExtension: "json"),
              let data = try? Data(contentsOf: url), let root = JSON.object(data) else { return [] }
        return root.objects("stickers").compactMap { o in
            guard let id = o.str("id"), let code = o.str("code") else { return nil }
            return Sticker(id: id, code: code, width: o.int("w") ?? 0, height: o.int("h") ?? 0, animated: o.bool("anim") ?? false)
        }
    }()

    static let byId: [String: Sticker] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func token(_ s: Sticker) -> String { "\(Stickers.start)\(s.id)\(Stickers.end)" }

    /// Текст сообщения кусками: текст и стикеры на своих местах.
    static func parts(_ text: String) -> [Part] {
        var out: [Part] = []
        var buffer = ""
        var id = ""
        var inside = false
        for c in text {
            if c == Stickers.start {
                if inside { buffer += id }
                inside = true
                id = ""
            } else if c == Stickers.end, inside {
                if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
                out.append(.image(id))
                inside = false
            } else if inside {
                id.append(c)
                if id.count > 40 { buffer += id; id = ""; inside = false }
            } else {
                buffer.append(c)
            }
        }
        if inside { buffer += id }
        if !buffer.isEmpty { out.append(.text(buffer)) }
        return out
    }

    /// Только стикеры (1–3) без текста: показываются крупно, без пузыря.
    static func stickerOnly(_ text: String) -> [String]? {
        let p = parts(text)
        var ids: [String] = []
        for part in p {
            switch part {
            case .text(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            case .image(let id): ids.append(id)
            }
        }
        return (1...3).contains(ids.count) ? ids : nil
    }

    /// Подсказки по тексту перед курсором: стикеры, чей код начинается с последних слов (как `Stickers.suggest`).
    static func suggest(_ before: String, limit: Int = 8) -> [(Sticker, Int)] {
        var tail = ""
        for c in before.reversed() {
            if c == Stickers.start || c == Stickers.end || c == "\n" { break }
            tail.insert(c, at: tail.startIndex)
            if tail.count >= 40 { break }
        }
        let chars = Array(tail)
        var out: [(Sticker, Int)] = []
        var seen = Set<String>()
        for i in chars.indices {
            if chars[i].isWhitespace || (i > 0 && !chars[i - 1].isWhitespace) { continue }
            let piece = String(chars[i...])
            for s in all where !seen.contains(s.id) {
                let fits = piece.count < 2 ? s.code.caseInsensitiveCompare(piece) == .orderedSame
                                           : s.code.lowercased().hasPrefix(piece.lowercased())
                if fits { seen.insert(s.id); out.append((s, piece.count)) }
            }
        }
        return Array(out.prefix(limit))
    }
}

/// Картинка стикера; анимированные WebP крутятся (ImageIO умеет WebP с iOS 14).
struct StickerImage: UIViewRepresentable {
    let id: String
    var height: CGFloat = 96

    private static var cache: [String: UIImage] = [:]

    static func image(_ id: String) -> UIImage? {
        if let i = cache[id] { return i }
        guard let url = StickerStore.byId[id]?.url ?? Bundle.main.url(forResource: id, withExtension: "webp"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        var result: UIImage?
        if count > 1 {
            var frames: [UIImage] = []
            var total = 0.0
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                frames.append(UIImage(cgImage: cg))
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                let delay = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0.1
                total += max(0.02, delay)
            }
            result = UIImage.animatedImage(with: frames, duration: total)
        } else if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            result = UIImage(cgImage: cg)
        }
        if let r = result { cache[id] = r }
        return result
    }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.clipsToBounds = true
        v.image = Self.image(id)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        v.image = Self.image(id)
    }
}

extension View {
    /// Размер стикера по его пропорциям.
    func stickerFrame(_ id: String, height: CGFloat) -> some View {
        let aspect = StickerStore.byId[id]?.aspect ?? 1
        return frame(width: height * aspect, height: height)
    }
}

/// Панель стикеров вместо клавиатуры, как на Android: сетка по 4 с подписью-кодом;
/// тап отправляет стикер, долгое нажатие показывает его крупно.
struct StickerPanel: View {
    let pick: (StickerStore.Sticker) -> Void
    @State private var zoomed: StickerStore.Sticker?

    private var side: CGFloat { ((UIMetrics.width - 16 * 2 - 12 * 3) / 4).rounded(.down) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 12), count: 4), spacing: 10) {
                ForEach(StickerStore.all) { s in
                    VStack(spacing: 3) {
                        StickerImage(id: s.id)
                            .frame(width: side - 8, height: side - 8)
                        Text(s.code).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                    .frame(width: side)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(s) }
                    .onLongPressGesture { zoomed = s }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .overlay(zoomed.map { s in
            ZStack {
                Color.black.opacity(0.6)
                StickerImage(id: s.id).frame(width: 200, height: 200)
            }
            .onTapGesture { zoomed = nil }
        })
    }
}
