import Foundation
import BackgroundTasks

/// Фоновая проверка чатов (SOC-1xx, Android 2.2.1 «уведомления при закрытом приложении»): push на iOS без сервера нет,
/// поэтому система раз в ~30 минут даёт приложению поработать — оно подключается к релеям на 20 секунд,
/// новые сообщения приходят уведомлениями (`ChatNotifier`).
enum BackgroundRefresh {
    static let chatsTask = "com.drxwnify.ios.chats"
    private static let window: TimeInterval = 20
    static weak var chats: ChatHub?

    /// Регистрация — до конца запуска приложения (`DrxwnifyApp.init`).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: chatsTask, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refresh)
        }
    }

    /// Следующая проверка не раньше чем через 30 минут (точное время выбирает система).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: chatsTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        final class Flag { var done = false }
        let flag = Flag()
        let finish: () -> Void = {
            DispatchQueue.main.async {
                guard !flag.done else { return }
                flag.done = true
                chats?.hold("background", false)
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = finish
        DispatchQueue.main.async {
            guard let hub = chats else { return finish() }
            hub.hold("background", true)
            DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: finish)
        }
    }
}
