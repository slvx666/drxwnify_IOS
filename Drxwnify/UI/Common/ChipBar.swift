import SwiftUI
import UIKit

/// Горизонтальный ряд фильтров-«капсул» на UIKit.
///
/// На SwiftUI (`ScrollView(.horizontal)` + `Button`) на iOS 16 нажатия в таком ряду массово терялись: журнал касаний
/// показал, что палец попадал точно в капсулу, главный поток был свободен, но жест кнопки SwiftUI к касанию даже не
/// подключался — фильтры поиска срабатывали с десятой попытки. UIKit-нажатие на прокрутке срабатывает надёжно.
struct ChipBar: UIViewRepresentable {
    struct Item: Equatable {
        let id: String
        let title: String
    }

    let items: [Item]
    let selected: String?
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 16
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.backgroundColor = .clear
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -horizontalPadding),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.stack = stack
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        if c.items != items { c.rebuild(items, height: height) }
        c.style(selected: selected)
    }

    final class Coordinator: NSObject {
        weak var stack: UIStackView?
        var items: [Item] = []
        var chips: [UILabel] = []
        var onSelect: (String) -> Void = { _ in }

        /// Капсулы — просто подписи; нажатие ловит один `UITapGestureRecognizer` на всей прокрутке. Так ряд листается,
        /// даже если палец лёг на капсулу (с `UIButton` прокрутка с капсулы не начиналась — журнал 0.12.9), а сдвиг
        /// пальца отменяет нажатие сам.
        func attach(_ scroll: UIScrollView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            scroll.addGestureRecognizer(tap)
        }

        func rebuild(_ items: [Item], height: CGFloat) {
            self.items = items
            chips.forEach { $0.removeFromSuperview() }
            chips = items.map { item in
                let l = PaddedLabel()
                l.text = item.title
                let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                l.font = AppTheme.current.monospaced
                    ? .monospacedSystemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size, weight: .medium)
                l.textAlignment = .center
                l.layer.cornerRadius = height / 2
                l.layer.cornerCurve = .continuous
                l.clipsToBounds = true
                l.isAccessibilityElement = true
                l.translatesAutoresizingMaskIntoConstraints = false
                l.heightAnchor.constraint(equalToConstant: height).isActive = true
                stack?.addArrangedSubview(l)
                return l
            }
        }

        func style(selected: String?) {
            let accent = AppTheme.current.palette.map { UIColor(hex: $0.accent) } ?? UIColor(Color.accentColor)
            for (i, l) in chips.enumerated() {
                let on = items[i].id == selected
                l.backgroundColor = on ? accent : UIColor.secondaryLabel.withAlphaComponent(0.2)
                l.textColor = on ? .systemBackground : .label
                l.accessibilityTraits = on ? [.button, .selected] : .button
            }
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            // Ближайшая капсула по горизонтали: промах в щель между ними тоже засчитывается соседней.
            var best: (Int, CGFloat)?
            for (i, l) in chips.enumerated() {
                let x = g.location(in: l).x
                let d = x < 0 ? -x : max(0, x - l.bounds.width)
                if d <= 6, best == nil || d < best!.1 { best = (i, d) }
            }
            guard let i = best?.0 else { return }
            let l = chips[i]
            l.alpha = 0.6
            UIView.animate(withDuration: 0.2) { l.alpha = 1 }
            onSelect(items[i].id)
        }
    }
}

/// Подпись с отступами слева и справа — капсула фильтра.
private final class PaddedLabel: UILabel {
    var inset: CGFloat = 16
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset * 2, height: s.height)
    }
}
