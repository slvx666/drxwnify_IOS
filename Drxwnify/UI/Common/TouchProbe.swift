import UIKit
import UIKit.UIGestureRecognizerSubclass
import os
import Combine

/// Диагностика «нажатие не срабатывает с первого раза»: пишет в системный журнал (подсистема `com.drxwnify.probe`)
/// каждое касание — где, сколько держали, насколько сдвинулся палец, — какие жесты его видели и в каком состоянии,
/// отменила ли система касание; и подвисания главного потока дольше 100 мс. Ничего не перехватывает и не задерживает.
/// Читать с ПК: `pymobiledevice3 syslog live -m Drxwnify | grep PROBE`.
final class TouchProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let log = OSLog(subsystem: "com.drxwnify.probe", category: "touch")
    private static var installed = false

    static func install() {
        DispatchQueue.main.async {
            guard !installed else { return }
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
            guard let w = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { install() }
                return
            }
            installed = true
            let p = TouchProbe(target: nil, action: nil)
            p.cancelsTouchesInView = false
            p.delaysTouchesBegan = false
            p.delaysTouchesEnded = false
            p.delegate = p
            w.addGestureRecognizer(p)
            HangWatch.start()
            note("installed")
        }
    }

    static func note(_ s: String) {
        os_log("PROBE %{public}@", log: log, type: .default, s)
    }

    private var began: [ObjectIdentifier: (time: TimeInterval, point: CGPoint)] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            let p = t.location(in: view)
            began[ObjectIdentifier(t)] = (t.timestamp, p)
            let lag = (ProcessInfo.processInfo.systemUptime - t.timestamp) * 1000
            Self.note(String(format: "down %.0f,%.0f lag=%.0fms view=%@ screen=%@", p.x, p.y, lag,
                             t.view.map { String(describing: type(of: $0)) } ?? "-", Self.screen(of: t.view)))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, "up") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, "CANCEL") }

    private func finish(_ touches: Set<UITouch>, _ what: String) {
        for t in touches {
            let p = t.location(in: view)
            let b = began.removeValue(forKey: ObjectIdentifier(t))
            let held = b.map { (t.timestamp - $0.time) * 1000 } ?? -1
            let moved = b.map { hypot(p.x - $0.point.x, p.y - $0.point.y) } ?? -1
            let gr = (t.gestureRecognizers ?? []).filter { $0 !== self }
                .map { "\(String(describing: type(of: $0))):\(Self.name($0.state))" }.joined(separator: " ")
            Self.note(String(format: "%@ %.0f,%.0f held=%.0fms moved=%.1f force=%.2f gr=[%@]", what, p.x, p.y, held, moved, t.force, gr))
        }
        if began.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        began.removeAll()
    }

    /// Название экрана навигации, в который попало касание (заголовок; нет — «?»), и глубина стека.
    private static func screen(of v: UIView?) -> String {
        var r: UIResponder? = v
        while let cur = r {
            if let vc = cur as? UIViewController, let nav = vc.parent as? UINavigationController {
                let title = vc.navigationItem.title ?? vc.title ?? "?"
                return "\(title)#\(nav.viewControllers.count)" + (vc.presentingViewController != nil || nav.presentingViewController != nil ? "(sheet)" : "")
            }
            r = cur.next
        }
        return "-"
    }

    private static func name(_ s: UIGestureRecognizer.State) -> String {
        switch s {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ENDED"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}

/// Подвисания главного потока: раз в 100 мс отдельный поток стучится в главный; не ответил за 100 мс — в журнал,
/// сколько он был занят.
enum HangWatch {
    static func start() {
        let t = Thread {
            while true {
                let sem = DispatchSemaphore(value: 0)
                let t0 = CACurrentMediaTime()
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 0.1) == .timedOut {
                    sem.wait()
                    TouchProbe.note(String(format: "HANG %.0fms", (CACurrentMediaTime() - t0) * 1000))
                }
                usleep(100_000)
            }
        }
        t.name = "HangWatch"
        t.qualityOfService = .utility
        t.start()
    }
}

/// Замер куска кода на главном потоке: дольше `over` мс — в журнал.
@inline(__always) func probeTime<T>(_ label: String, over: Double = 16, _ body: () throws -> T) rethrows -> T {
    let t0 = CACurrentMediaTime()
    defer {
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > over { TouchProbe.note(String(format: "slow %@ %.0fms", label, ms)) }
    }
    return try body()
}

/// Сколько раз перерисовывались экраны: сводка в журнал раз в 2 с (только если что-то перерисовывалось).
enum RenderCount {
    private static var counts: [String: Int] = [:]
    private static var timer: Timer?

    static func hit(_ name: String) {
        counts[name, default: 0] += 1
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                guard !counts.isEmpty else { return }
                TouchProbe.note("renders " + counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                counts = [:]
            }
        }
    }
}

/// Кто будит перерисовку: сколько раз каждый общий объект объявил об изменении — сводка раз в 2 с.
enum ChangeWatch {
    private static var counts: [String: Int] = [:]
    private static var bag = Set<AnyCancellable>()
    private static var timer: Timer?

    static func watch(_ name: String, _ publisher: ObservableObjectPublisher) {
        publisher.sink { _ in counts[name, default: 0] += 1 }.store(in: &bag)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                guard !counts.isEmpty else { return }
                TouchProbe.note("changes " + counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                counts = [:]
            }
        }
    }
}
