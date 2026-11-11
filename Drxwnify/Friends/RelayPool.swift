import Foundation

/// Пул релеев Nostr — перенос `friends/RelayPool.kt` (CRITICAL §1.1).
/// Сокет открывается по требованию и закрывается через 90 с без подписок и отправок; отправка — не больше 8 событий/с
/// (запас 20); подтверждения OK ждут 60 с. Публикация и подписка идут во все релеи.
final class RelayPool {
    static let shared = RelayPool()

    static let relays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://nostr.mom",
        "wss://relay.snort.social",
        // Не за Cloudflare: работают там, где его режут.
        "wss://offchain.pub",
        "wss://nostr.oxtr.dev",
        "wss://nostr-pub.wellorder.net",
        "wss://nostr.einundzwanzig.space",
    ]

    private static let idleClose: TimeInterval = 90
    private static let burst = 20.0
    private static let perSecond = 8.0
    private static let ackKeep: TimeInterval = 60

    typealias Ack = (_ relay: String, _ ok: Bool, _ reason: String) -> Void

    private final class Relay {
        let url: String
        var task: URLSessionWebSocketTask?
        var open = false
        var pending: [String] = []
        var outbox: [String] = []
        var writing = false
        var failures = 0
        var tokens = RelayPool.burst
        var tokensAt = Date()

        init(url: String) { self.url = url }
    }

    private struct Subscription {
        var filters: [JSONObject]
        var onEose: (() -> Void)?
        var onEvent: (NostrEvent) -> Void
    }

    private let queue = DispatchQueue(label: "drxw.relays")
    private let session = URLSession(configuration: .default)
    private var pool: [String: Relay] = [:]
    private var subscriptions: [String: Subscription] = [:]
    private var acks: [String: Ack] = [:]
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var verified = Set<String>()
    private var verifiedOrder: [String] = []
    private var lastUse = Date()
    private var idleTimer: DispatchSourceTimer?

    /// Вызывается, когда какой-нибудь релей открылся (чаты досылают черновики).
    var onOpen: (() -> Void)?

    private init() {
        for url in Self.relays { pool[url] = Relay(url: url) }
    }

    // MARK: - Публичное

    func publish(_ event: NostrEvent, onAck: Ack? = nil) {
        if let onAck = onAck { listen(event.id, onAck) }
        let message = JSON.string(["EVENT", event.json] as [Any])
        queue.async { for r in self.pool.values { self.send(r, message) } }
    }

    func listen(_ eventId: String, _ onAck: @escaping Ack) {
        queue.async {
            self.acks[eventId] = onAck
            self.queue.asyncAfter(deadline: .now() + Self.ackKeep) { self.acks[eventId] = nil }
        }
    }

    @discardableResult
    func subscribe(_ filters: [JSONObject], onEose: (() -> Void)? = nil, onEvent: @escaping (NostrEvent) -> Void) -> String {
        let id = "drxw" + String(UUID().uuidString.lowercased().prefix(8))
        queue.async {
            self.subscriptions[id] = Subscription(filters: filters, onEose: onEose, onEvent: onEvent)
            let message = Self.reqMessage(id, filters)
            for r in self.pool.values { self.send(r, message) }
        }
        return id
    }

    func close(_ subscriptionId: String) {
        queue.async {
            guard self.subscriptions.removeValue(forKey: subscriptionId) != nil else { return }
            let message = JSON.string(["CLOSE", subscriptionId] as [Any])
            for r in self.pool.values where r.open { r.task?.send(.string(message)) { _ in } }
        }
    }

    var openCount: Int { queue.sync { pool.values.filter { $0.open }.count } }

    /// Сеть вернулась: релеи переподключаются сразу.
    func reconnectNow() {
        queue.async {
            for r in self.pool.values {
                r.failures = 0
                if r.task == nil && (!self.subscriptions.isEmpty || !r.pending.isEmpty) { self.connect(r) }
            }
        }
    }

    private static func reqMessage(_ id: String, _ filters: [JSONObject]) -> String {
        JSON.string((["REQ", id] as [Any]) + filters.map { $0 as Any })
    }

    // MARK: - Отправка (очередь `queue`)

    private func send(_ relay: Relay, _ message: String) {
        lastUse = Date()
        scheduleIdleClose()
        if relay.task != nil && relay.open {
            relay.outbox.append(message)
            drain(relay)
            return
        }
        relay.pending.append(message)
        if relay.task == nil { connect(relay) }
    }

    /// Ведро токенов: 8 сообщений в секунду, запас 20.
    private func drain(_ relay: Relay) {
        guard !relay.writing else { return }
        relay.writing = true
        func step() {
            guard !relay.outbox.isEmpty else {
                relay.writing = false
                return
            }
            let now = Date()
            relay.tokens = min(Self.burst, relay.tokens + now.timeIntervalSince(relay.tokensAt) * Self.perSecond)
            relay.tokensAt = now
            if relay.tokens < 1 {
                queue.asyncAfter(deadline: .now() + (1 - relay.tokens) / Self.perSecond) { step() }
                return
            }
            relay.tokens -= 1
            let message = relay.outbox.removeFirst()
            if let task = relay.task, relay.open {
                task.send(.string(message)) { _ in }
            } else {
                relay.pending.append(message)
            }
            step()
        }
        step()
    }

    private func connect(_ relay: Relay) {
        guard let url = URL(string: relay.url) else { return }
        let task = session.webSocketTask(with: url)
        relay.task = task
        relay.open = false
        task.resume()
        // Открытие сокета узнаём по первому успешному ping.
        task.sendPing { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                guard relay.task === task else { return }
                if error != nil {
                    relay.failures += 1
                    self.dropped(relay, task)
                } else {
                    self.opened(relay)
                }
            }
        }
        receive(relay, task)
    }

    private func opened(_ relay: Relay) {
        relay.open = true
        relay.failures = 0
        // Подписки, начатые, пока релей был недоступен, идут и сюда.
        let queued = relay.pending
        relay.pending = []
        var reqIds = Set<String>()
        for m in queued {
            if let a = (try? JSONSerialization.jsonObject(with: Data(m.utf8))) as? [Any], a.first as? String == "REQ", let id = a[1] as? String {
                reqIds.insert(id)
            }
        }
        for (id, sub) in subscriptions where !reqIds.contains(id) { relay.outbox.append(Self.reqMessage(id, sub.filters)) }
        relay.outbox.append(contentsOf: queued)
        drain(relay)
        if let cb = onOpen { DispatchQueue.main.async(execute: cb) }
        keepAlive(relay, relay.task)
    }

    /// Ping каждые 30 с, как OkHttp pingInterval на Android.
    private func keepAlive(_ relay: Relay, _ task: URLSessionWebSocketTask?) {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, let task = task, relay.task === task, relay.open else { return }
            task.sendPing { error in
                self.queue.async {
                    if error != nil, relay.task === task {
                        relay.failures += 1
                        self.dropped(relay, task)
                    } else {
                        self.keepAlive(relay, task)
                    }
                }
            }
        }
    }

    private func receive(_ relay: Relay, _ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                var text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                self.queue.async {
                    if !relay.open && relay.task === task { self.opened(relay) }
                    if let t = text { self.handle(relay, t) }
                }
                self.receive(relay, task)
            case .failure:
                self.queue.async {
                    relay.failures += 1
                    self.dropped(relay, task)
                }
            }
        }
    }

    private func dropped(_ relay: Relay, _ task: URLSessionWebSocketTask) {
        guard relay.task === task else { return }
        task.cancel(with: .goingAway, reason: nil)
        relay.task = nil
        relay.open = false
        relay.writing = false
        relay.pending.insert(contentsOf: relay.outbox, at: 0)
        relay.outbox = []
        // Живые подписки возвращаются после паузы: 10 с, после каждой неудачи подряд дольше (до 5 мин), с разбросом.
        guard !subscriptions.isEmpty else { return }
        let wait = min(10.0 * Double(1 << min(relay.failures, 5)), 300)
        queue.asyncAfter(deadline: .now() + wait + Double.random(in: 0...(wait / 5))) {
            if relay.task == nil && !self.subscriptions.isEmpty { self.connect(relay) }
        }
    }

    private func remember(_ set: inout Set<String>, _ order: inout [String], _ key: String) -> Bool {
        guard set.insert(key).inserted else { return false }
        order.append(key)
        if order.count > 4000 { set.remove(order.removeFirst()) }
        return true
    }

    private func handle(_ relay: Relay, _ text: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any], let type = message.first as? String else { return }
        switch type {
        case "OK":
            guard message.count >= 3, let id = message[1] as? String else { return }
            let ok = (message[2] as? Bool) ?? false
            let reason = message.count > 3 ? (message[3] as? String ?? "") : ""
            if let ack = acks[id] { DispatchQueue.main.async { ack(relay.url, ok, reason) } }
        case "EOSE":
            guard message.count >= 2, let id = message[1] as? String, let cb = subscriptions[id]?.onEose else { return }
            DispatchQueue.main.async(execute: cb)
        case "EVENT":
            guard message.count >= 3, let subId = message[1] as? String, let sub = subscriptions[subId],
                  let o = message[2] as? JSONObject, let event = NostrEvent(json: o) else { return }
            guard remember(&seen, &seenOrder, subId + event.id) else { return }
            // Одно событие приходит от каждого релея и снова при каждой подписке: подпись проверяется один раз, дальше хватает id.
            guard event.hasValidId else { return }
            if !verified.contains(event.id) {
                guard event.hasValidSignature else { return }
                _ = remember(&verified, &verifiedOrder, event.id)
            }
            lastUse = Date()
            let cb = sub.onEvent
            DispatchQueue.main.async { cb(event) }
        default:
            break
        }
    }

    private func scheduleIdleClose() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleClose / 3, repeating: Self.idleClose / 3)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.subscriptions.isEmpty && Date().timeIntervalSince(self.lastUse) > Self.idleClose {
                for r in self.pool.values {
                    r.task?.cancel(with: .normalClosure, reason: nil)
                    r.task = nil
                    r.open = false
                    r.pending = []
                    r.outbox = []
                    r.writing = false
                }
                self.idleTimer?.cancel()
                self.idleTimer = nil
            }
        }
        idleTimer = timer
        timer.resume()
    }
}
