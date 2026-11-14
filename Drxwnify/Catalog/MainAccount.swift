import Foundation
import Combine

/// Сервис каталога (Android `MetadataSource`).
enum CatalogSource: String, CaseIterable, Identifiable {
    case SPOTIFY, YANDEX, VK
    var id: String { rawValue }

    var title: String {
        switch self {
        case .SPOTIFY: return "Spotify"
        case .YANDEX: return L("yandex_music")
        case .VK: return L("vk_music_name")
        }
    }

    /// Короткое имя для фишки библиотеки.
    var shortTitle: String {
        switch self {
        case .SPOTIFY: return "Spotify"
        case .YANDEX: return L("yandex_tab_short")
        case .VK: return "VK"
        }
    }

    var symbol: String {
        switch self {
        case .SPOTIFY: return "music.note"
        case .YANDEX: return "y.circle"
        case .VK: return "music.note.house"
        }
    }

    /// Чей это id: `ym_` — Яндекс, `src:VK:`/`vk_`/`vkar_` — ВК, остальное — Spotify.
    static func of(_ id: String?) -> CatalogSource {
        if YandexIds.isYandex(id) { return .YANDEX }
        if VkIds.isVk(id) { return .VK }
        return .SPOTIFY
    }
}

/// Основной аккаунт и всё, что связано с привязанными (Android 2.3.0 `catalog/MainAccount.kt`):
/// - основной (медиатека, главная, рекомендации, цвет, профиль для друзей);
/// - вкладка другого аккаунта в библиотеке (по умолчанию выключена, `accountTab_<SOURCE>`);
/// - куда уходит лайк (`likeMode`).
/// Перелогин основной не меняет: только первое подключение (Spotify всегда; другой сервис — если основного ещё нет)
/// и выбор пользователя на странице аккаунта.
final class MainAccount: ObservableObject {
    enum LikeMode: String, CaseIterable, Identifiable {
        case MAIN_ONLY, MAIN_AND_SOURCE, ALL
        var id: String { rawValue }
        var title: String {
            switch self {
            case .MAIN_ONLY: return L("like_mode_main_only")
            case .MAIN_AND_SOURCE: return L("like_mode_main_and_source")
            case .ALL: return L("like_mode_all")
            }
        }
    }

    static let shared = MainAccount()
    private static let likeModeKey = PrefKey<String>("likeMode", .string)
    private static func tabKey(_ s: CatalogSource) -> PrefKey<Bool> { PrefKey<Bool>("accountTab_\(s.rawValue)", .bool) }

    private(set) var settings: TypedStore?
    /// Растёт при смене основного аккаунта: главная и медиатека собираются заново.
    @Published private(set) var revision = 0
    private var bag = Set<AnyCancellable>()

    func configure(_ settings: TypedStore) {
        self.settings = settings
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &bag)
        pinCurrent()
    }

    func isLinked(_ s: CatalogSource) -> Bool {
        guard let st = settings else { return false }
        switch s {
        case .SPOTIFY: return !(st.get(PK.spotifySpDc) ?? "").isEmpty
        case .YANDEX: return !(st.get(PK.yandexAccessToken) ?? "").isEmpty
        case .VK: return !(st.get(PK.vkAccessToken) ?? "").isEmpty
        }
    }

    var linked: [CatalogSource] { CatalogSource.allCases.filter(isLinked) }

    /// Основной: выбранный, если привязан; иначе Spotify, Яндекс, ВК — первый привязанный; nil — нет ни одного.
    var main: CatalogSource? {
        if let raw = settings?.get(PK.primaryMetadataSource), let s = CatalogSource(rawValue: raw), isLinked(s) { return s }
        return linked.first
    }

    /// Запоминает текущий основной, чтобы следующий вход в другой сервис его не сменил (кроме Spotify — как на Android).
    func pinCurrent() {
        guard let st = settings, let m = main else { return }
        if st.get(PK.primaryMetadataSource) != m.rawValue { st.set(PK.primaryMetadataSource, m.rawValue) }
    }

    /// Аккаунт только что привязан: `wasLinked` — был ли он привязан до входа (перелогин основной не меняет).
    func didLink(_ s: CatalogSource, wasLinked: Bool, mainBefore: CatalogSource?) {
        if wasLinked { return }
        if s == .SPOTIFY || mainBefore == nil || mainBefore == s { choose(s) } else { pinCurrentTo(mainBefore) }
    }

    private func pinCurrentTo(_ s: CatalogSource?) {
        guard let s = s else { return }
        settings?.set(PK.primaryMetadataSource, s.rawValue)
    }

    /// Делает аккаунт основным. Ничего не удаляется; экраны, которые от него зависят, собираются заново.
    func choose(_ s: CatalogSource) {
        guard let st = settings else { return }
        let before = main
        st.set(PK.primaryMetadataSource, s.rawValue)
        if before != s { changed() }
    }

    /// Выход из аккаунта: вкладка выключается, основной переходит к следующему привязанному.
    func didUnlink(_ s: CatalogSource) {
        setTab(s, false)
        if settings?.get(PK.primaryMetadataSource) == s.rawValue {
            if let next = linked.first { settings?.set(PK.primaryMetadataSource, next.rawValue) } else { settings?.set(PK.primaryMetadataSource, nil) }
        }
        changed()
    }

    private func changed() {
        DispatchQueue.main.async { self.revision += 1 }
        NotificationCenter.default.post(name: .mainAccountChanged, object: nil)
    }

    // MARK: - Вкладки и лайки

    func tabShown(_ s: CatalogSource) -> Bool { settings?.get(Self.tabKey(s)) ?? false }

    func setTab(_ s: CatalogSource, _ shown: Bool) {
        settings?.set(Self.tabKey(s), shown)
        objectWillChange.send()
    }

    /// Вкладки библиотеки: привязанные, не основной, включённые на странице аккаунта.
    var tabs: [CatalogSource] { linked.filter { $0 != main && tabShown($0) } }

    var likeMode: LikeMode {
        get { settings?.get(Self.likeModeKey).flatMap(LikeMode.init(rawValue:)) ?? .MAIN_AND_SOURCE }
        set { settings?.set(Self.likeModeKey, newValue.rawValue); objectWillChange.send() }
    }
}

extension Notification.Name {
    static let mainAccountChanged = Notification.Name("drx.mainAccountChanged")
}
