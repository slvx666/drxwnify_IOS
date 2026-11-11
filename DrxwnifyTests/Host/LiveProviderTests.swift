import Foundation

/// Живая проверка источников (сеть): запускается только с переменной LIVE=1.
/// Ищет известный трек и проверяет, что источник отдаёт поток, который отвечает на запрос.
func testProvidersLive() {
    guard ProcessInfo.processInfo.environment["LIVE"] == "1" else { return }
    section("Источники вживую")
    let q = AudioQuery(catalogId: nil, title: "Get Lucky (feat. Pharrell Williams and Nile Rodgers)", artists: ["Daft Punk", "Pharrell Williams", "Nile Rodgers"],
                       album: "Random Access Memories", durationMs: 369_000, isrc: "USQX91300108")
    let providers: [AudioProvider] = [YouTubeProvider(), BandcampProvider(), AudiusProvider()]
    let done = DispatchSemaphore(value: 0)
    Task {
        for p in providers {
            do {
                guard let m = try await p.search(q) else {
                    print("  ..   \(p.id.rawValue): не нашёл или нет потока (не ошибка: зависит от сети и каталога)")
                    continue
                }
                print("  ..   \(p.id.rawValue): \(m.artist) — \(m.title), conf \(String(format: "%.2f", m.confidence))")
                guard let s = try await p.stream(q, match: m) else {
                    expect(false, "\(p.id.rawValue): поток")
                    continue
                }
                var headers = s.headers
                headers["Range"] = "bytes=0-2047"
                let r = try await HTTP.get(s.url, headers: headers, timeout: 15)
                expect(r.status == 206 || r.status == 200, "\(p.id.rawValue): поток отвечает (HTTP \(r.status), \(r.data.count) байт, \(s.mimeType), \(s.bitrate / 1000) kbps)")
            } catch {
                expect(false, "\(p.id.rawValue): \(error.localizedDescription)")
            }
        }
        done.signal()
    }
    done.wait()
}
