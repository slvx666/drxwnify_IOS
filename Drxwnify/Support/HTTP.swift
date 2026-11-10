import Foundation

/// Обёртка над `URLSession` с async/await, работающая с iOS 14
/// (`URLSession.data(for:)` появился только в iOS 15).
enum HTTP {
    struct Response {
        let data: Data
        let status: Int
        let headers: [AnyHashable: Any]

        var text: String { String(data: data, encoding: .utf8) ?? "" }
        var isSuccess: Bool { (200...299).contains(status) }

        func header(_ name: String) -> String? {
            for (key, value) in headers {
                if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                    return value as? String
                }
            }
            return nil
        }
    }

    /// Сессия без системного хранилища cookie: cookie задаём сами, заголовком.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest, session: URLSession = HTTP.session) async throws -> Response {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        cont.resume(throwing: error)
                        return
                    }
                    let http = response as? HTTPURLResponse
                    cont.resume(returning: Response(data: data ?? Data(),
                                                    status: http?.statusCode ?? 0,
                                                    headers: http?.allHeaderFields ?? [:]))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await send(request)
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}

/// Пауза, отменяемая вместе с задачей (`Task.sleep(nanoseconds:)` доступен с iOS 13).
func sleepSeconds(_ seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}
