import SwiftUI
import UIKit

/// Горизонтальный ряд фильтров-«капсул» на UIKit.
///
/// На SwiftUI (`ScrollView(.horizontal)` + `Button`) на iOS 16 нажатия в таком ряду массово терялись: журнал касаний
/// показал, что палец попадал точно в капсулу, главный поток был свободен, но жест кнопки SwiftUI к касанию даже не
/// подключался — фильтры поиска срабатывали с десятой попытки. `UIButton` в `UIScrollView` получает касание напрямую.
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
        // Касание уходит кнопке сразу, без задержки на «а вдруг это прокрутка»; сдвиг пальца всё равно прокручивает.
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
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
        var buttons: [UIButton] = []
        var onSelect: (String) -> Void = { _ in }

        func rebuild(_ items: [Item], height: CGFloat) {
            self.items = items
            buttons.forEach { $0.removeFromSuperview() }
            buttons = items.enumerated().map { i, item in
                let b = UIButton(type: .custom)
                b.tag = i
                b.setTitle(item.title, for: .normal)
                let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                b.titleLabel?.font = AppTheme.current.monospaced
                    ? .monospacedSystemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size, weight: .medium)
                b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
                b.layer.cornerRadius = height / 2
                b.layer.cornerCurve = .continuous
                b.clipsToBounds = true
                b.translatesAutoresizingMaskIntoConstraints = false
                b.heightAnchor.constraint(equalToConstant: height).isActive = true
                b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
                b.addTarget(self, action: #selector(press(_:)), for: [.touchDown, .touchDragEnter])
                b.addTarget(self, action: #selector(release(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
                stack?.addArrangedSubview(b)
                return b
            }
        }

        func style(selected: String?) {
            let accent = AppTheme.current.palette.map { UIColor(hex: $0.accent) } ?? UIColor(Color.accentColor)
            for (i, b) in buttons.enumerated() {
                let on = items[i].id == selected
                b.backgroundColor = on ? accent : UIColor.secondaryLabel.withAlphaComponent(0.2)
                b.setTitleColor(on ? .systemBackground : .label, for: .normal)
                b.accessibilityTraits = on ? [.button, .selected] : .button
            }
        }

        @objc private func tap(_ b: UIButton) {
            guard items.indices.contains(b.tag) else { return }
            onSelect(items[b.tag].id)
        }

        @objc private func press(_ b: UIButton) { b.alpha = 0.6 }
        @objc private func release(_ b: UIButton) { UIView.animate(withDuration: 0.15) { b.alpha = 1 } }
    }
}
