#if DEBUG
import UIKit

/// Снимок окна процессором (`CALayer.render(in:)`) — для симулятора на VM без Metal, где экран симулятора чёрный.
/// `DRX_SNAPSHOT=<секунды>` (через `SIMCTL_CHILD_DRX_SNAPSHOT`): снимок каждые N секунд в
/// `Documents/drx-snapshot.png`. Стекло, размытие и анимации так не рисуются — только раскладка и цвета.
enum DebugSnapshot {
    static func startIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["DRX_SNAPSHOT"],
              let every = Double(raw), every > 0 else { return }
        Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in capture() }
    }

    static func capture() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden }
        guard let main = windows.first else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let image = UIGraphicsImageRenderer(bounds: main.bounds, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(main.bounds)
            // Все окна по порядку: листы и меню лежат в своих окнах/контроллерах поверх основного.
            for w in windows.sorted(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue }) {
                w.layer.render(in: ctx.cgContext)
            }
        }
        guard let data = image.pngData(),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let tmp = dir.appendingPathComponent("drx-snapshot.tmp.png")
        try? data.write(to: tmp)
        let dst = dir.appendingPathComponent("drx-snapshot.png")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.moveItem(at: tmp, to: dst)
    }
}
#endif
