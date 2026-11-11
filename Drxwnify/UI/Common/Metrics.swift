import SwiftUI
import UIKit

/// Размеры под экран телефона (пункт 0б): от 320×568 pt (SE 1, «Увеличенный» масштаб iPhone 8) до 440 pt ширины.
/// Только портрет, поэтому хватает `UIScreen.main.bounds`.
enum UIMetrics {
    static var width: CGFloat { UIScreen.main.bounds.width }
    static var height: CGFloat { UIScreen.main.bounds.height }
    /// 320 pt ширины.
    static var isNarrow: Bool { width < 360 }
    /// 568 pt высоты.
    static var isShort: Bool { height < 600 }

    /// Множитель от ширины: 1 на 390 pt и шире, 0,82 на 320 pt.
    static var scale: CGFloat {
        let s: CGFloat = width / 390
        return min(1, max(0.82, s))
    }

    /// Размер кнопки или обложки под ширину экрана.
    static func scaled(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded()
    }
}

/// Не даёт крупному шрифту (Dynamic Type) раздуть экраны с плотной компоновкой (плеер, мини-плеер).
struct CappedDynamicType: ViewModifier {
    @Environment(\.sizeCategory) private var size
    var limit: ContentSizeCategory = .extraLarge

    func body(content: Content) -> some View {
        let all = ContentSizeCategory.allCases
        let current = all.firstIndex(of: size) ?? 0
        let max = all.firstIndex(of: limit) ?? 0
        return content.environment(\.sizeCategory, current > max ? limit : size)
    }
}

extension View {
    func cappedDynamicType(_ limit: ContentSizeCategory = .extraLarge) -> some View {
        modifier(CappedDynamicType(limit: limit))
    }
}
