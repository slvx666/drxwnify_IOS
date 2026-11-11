import Foundation

/// Источники звука (CRITICAL §2.2). Имена — как в Android `AudioProviderId`: они лежат в настройке `audioSourceOrder` и в БД.
enum AudioProviderId: String, CaseIterable, Codable {
    case SOUNDCLOUD, YOUTUBE, VK, LOSSLESS, BANDCAMP, AUDIUS, SOULSEEK

    static let defaultOrder: [AudioProviderId] = [.SOUNDCLOUD, .YOUTUBE, .VK, .LOSSLESS, .BANDCAMP, .AUDIUS, .SOULSEEK]

    var typicalKbps: Int {
        switch self {
        case .YOUTUBE: return 160
        case .VK: return 320
        case .SOUNDCLOUD: return 160
        case .BANDCAMP: return 128
        case .AUDIUS: return 128
        case .LOSSLESS: return 1411
        case .SOULSEEK: return 320
        }
    }

    var displayName: String {
        switch self {
        case .SOUNDCLOUD: return "SoundCloud"
        case .YOUTUBE: return "YouTube"
        case .VK: return "VK"
        case .LOSSLESS: return "Lossless"
        case .BANDCAMP: return "Bandcamp"
        case .AUDIUS: return "Audius"
        case .SOULSEEK: return "Soulseek"
        }
    }

    /// Сохранённый порядок "A,B,C": неизвестные отбрасываются, отсутствующие дописываются в конец.
    static func parseOrder(_ stored: String?) -> [AudioProviderId] {
        guard let stored = stored, !stored.isEmpty else { return defaultOrder }
        var parsed: [AudioProviderId] = []
        for name in stored.split(separator: ",") {
            if let id = AudioProviderId(rawValue: name.trimmingCharacters(in: .whitespaces)), !parsed.contains(id) {
                parsed.append(id)
            }
        }
        return parsed + defaultOrder.filter { !parsed.contains($0) }
    }
}

/// Идентификаторы треков, звук которых идёт не с YouTube: `mfb:<id трека каталога>` (как на Android).
enum FallbackIds {
    static let prefix = "mfb:"
    static func of(_ catalogId: String) -> String { prefix + catalogId }
    static func catalogId(of mediaId: String) -> String? {
        if mediaId.hasPrefix(prefix) { return String(mediaId.dropFirst(prefix.count)) }
        if mediaId.hasPrefix("qbzfb:") { return String(mediaId.dropFirst(6)) }
        return nil
    }
}

struct AudioQuery: Hashable {
    var catalogId: String?
    var title: String
    var artists: [String]
    var album: String?
    var durationMs: Int
    var isrc: String?
    var excludedTrackIds: Set<String> = []

    var primaryArtist: String { artists.first ?? "" }

    var cacheKey: String {
        catalogId ?? "\(title.lowercased())|\(primaryArtist.lowercased())|\(durationMs / 1000)"
    }

    /// Текст для поиска в источнике: «артист название».
    var searchText: String {
        [primaryArtist, title].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct ProviderMatch: Hashable {
    var provider: AudioProviderId
    var trackId: String
    var title: String
    var artist: String
    var durationMs: Int?
    var confidence: Double
    var thumbnailUrl: String?
    var qualityKbps: Int?

    var expectedKbps: Int { qualityKbps ?? provider.typicalKbps }
}

struct AudioStream {
    var url: URL
    var mimeType: String
    var codecs: String
    var bitrate: Int
    var expiresAt: Date
    var headers: [String: String] = [:]
    var isHLS = false
}

protocol AudioProvider: AnyObject {
    var id: AudioProviderId { get }
    /// Верхняя граница одного поиска, секунды.
    var searchTimeout: TimeInterval { get }
    func isReady() -> Bool
    /// nil — честное «нет»; исключение — сбой или таймаут.
    func search(_ query: AudioQuery) async throws -> ProviderMatch?
    func stream(_ query: AudioQuery, match: ProviderMatch) async throws -> AudioStream?
    /// Несколько кандидатов для «Версии трека» (по умолчанию — только лучший).
    func versions(_ query: AudioQuery, limit: Int) async throws -> [ProviderMatch]
}

extension AudioProvider {
    func isReady() -> Bool { true }
    func versions(_ query: AudioQuery, limit: Int) async throws -> [ProviderMatch] {
        (try await search(query)).map { [$0] } ?? []
    }
}
