import UIKit
import Combine

/// Видна ли своя нижняя панель вкладок (iOS 14–25) и открыт ли чат.
///
/// Отдельно от `AppEnvironment`: на `env` подписано почти всё приложение, и раньше каждый переход между экранами
/// перерисовывал его целиком (подвисание 0,2–0,8 с на iPhone 8 — в это время нажатия терялись).
///
/// Панель видна, когда корень выбранной вкладки — верхний экран своей навигации. Это читается из самой навигации,
/// а не считается по событиям «появился/ушёл»: у вложенных контроллеров на iOS 16 они приходят не парами, счётчик
/// застревал, и панель пропадала прямо на корне (0.12.7). Теперь любое событие и раз в секунду — пересчёт по факту.
final class ChromeState: ObservableObject {
    static let shared = ChromeState()

    @Published private(set) var hidden = false
    /// Открыт чат: мини-плеер уходит, строка ввода стоит внизу (сообщил пользователь на 0.10.1).
    @Published var chatOpen = false
    var currentTab = "home" { didSet { if currentTab != oldValue { refresh() } } }

    private struct WeakRoot { weak var controller: TabRootController? }
    private var roots: [String: WeakRoot] = [:]
    private var pending = false
    private var timer: Timer?

    func register(_ c: TabRootController, root name: String) {
        roots[name] = WeakRoot(controller: c)
        if timer == nil {
            // Страховка: если UIKit не прислал ни одного события (бывает при быстрых переходах), панель всё равно
            // встанет как надо не позже чем через секунду. Перерисовка — только когда состояние поменялось.
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        }
        refresh()
    }

    /// Пересчитать на следующем витке главного потока (несколько событий подряд — один пересчёт).
    func refresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            self.pending = false
            self.update()
        }
    }

    /// Пересчитать сейчас и ещё раз, когда переход закончится — в том числе отменённый свайп назад.
    func refreshAround(_ c: UIViewController) {
        refresh()
        let nav = Self.page(of: c)?.nav
        if let tc = nav?.transitionCoordinator ?? c.transitionCoordinator {
            tc.animate(alongsideTransition: nil) { [weak self] _ in self?.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    private func update() {
        let h = !rootOnTop()
        if h != hidden {
            hidden = h
            TouchProbe.note("chrome hidden=\(h) tab=\(currentTab)")
        }
    }

    private func rootOnTop() -> Bool {
        guard let c = roots[currentTab]?.controller else { return true }
        // Вид ещё не в окне (запуск) — не знаем, показываем; в окне, но навигация не нашлась — по событиям появления.
        guard let p = Self.page(of: c) else { return c.viewIfLoaded?.window == nil || c.appeared }
        return p.nav.topViewController === p.page
    }

    /// Экран навигации, в котором стоит контроллер: идём по цепочке ответчиков от его вида вверх до контроллера,
    /// чей родитель — `UINavigationController`.
    static func page(of c: UIViewController) -> (page: UIViewController, nav: UINavigationController)? {
        var r: UIResponder? = c.viewIfLoaded?.superview
        while let cur = r {
            if let vc = cur as? UIViewController, vc !== c, let nav = vc.parent as? UINavigationController {
                return (vc, nav)
            }
            r = cur.next
        }
        return nil
    }
}
