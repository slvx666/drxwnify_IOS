import SwiftUI
import UIKit

/// Темы приложения (THEME-003, `ui/theme/AppThemes.kt`, настройка `appThemePreset`): тёмные палитры Android —
/// цвет акцента, фон, поверхности и текст; Gruvbox и Linux — моноширинный шрифт. Стандартная — системная.
enum AppTheme: String, CaseIterable, Identifiable {
    case standard = "STANDARD", gruvbox = "GRUVBOX", linux = "LINUX", sakura = "SAKURA", synthwave = "SYNTHWAVE", catppuccin = "CATPPUCCIN"

    var id: String { rawValue }

    var titleKey: String { "app_theme_" + rawValue.lowercased() }
    var descriptionKey: String { titleKey + "_desc" }

    struct Palette {
        var accent: UInt32
        var background: UInt32
        var surface: UInt32
        var text: UInt32
        var secondaryText: UInt32
    }

    /// Тёмные схемы из `AppThemes.kt` (primary, background, surfaceVariant, onSurface, onSurfaceVariant).
    var palette: Palette? {
        switch self {
        case .standard: return nil
        case .gruvbox: return Palette(accent: 0xFABD2F, background: 0x282828, surface: 0x3C3836, text: 0xEBDBB2, secondaryText: 0xBDAE93)
        case .linux: return Palette(accent: 0xFABD2F, background: 0x1D2021, surface: 0x32302F, text: 0xEBDBB2, secondaryText: 0xA89984)
        case .sakura: return Palette(accent: 0xF4A7BB, background: 0x1C171F, surface: 0x3A2E38, text: 0xF2E4EA, secondaryText: 0xD6C1CB)
        case .synthwave: return Palette(accent: 0xFF4FA8, background: 0x1A1033, surface: 0x34265A, text: 0xF3E8FF, secondaryText: 0xCBB8EE)
        case .catppuccin: return Palette(accent: 0xCBA6F7, background: 0x1E1E2E, surface: 0x313244, text: 0xCDD6F4, secondaryText: 0xBAC2DE)
        }
    }

    var monospaced: Bool { self == .gruvbox || self == .linux }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appThemePreset") ?? "") ?? .standard
    }

    var accent: Color? { palette.map { Color(UIColor(hex: $0.accent)) } }
    /// Фон строк простых списков: на iOS 16+ ячейки иначе системно-чёрные при цветном фоне темы.
    /// Карточки сгруппированных списков (настройки): чуть светлее фона, как карточки Android (bg → surface на 30 %).
    static var cardBackground: Color? {
        guard let p = current.palette else { return nil }
        func mix(_ shift: Int) -> CGFloat {
            let a = CGFloat((p.background >> shift) & 0xFF), b = CGFloat((p.surface >> shift) & 0xFF)
            return (a + (b - a) * 0.3) / 255
        }
        return Color(red: Double(mix(16)), green: Double(mix(8)), blue: Double(mix(0)))
    }

    static var rowBackground: Color { current.palette.map { Color(UIColor(hex: $0.background)) } ?? Color(.systemBackground) }

    /// Цвета UIKit-основы (списки, панели, навигация) — на них стоят экраны SwiftUI на iOS 14–25.
    func applyAppearance() {
        let tint = palette.map { UIColor(hex: $0.accent) }
        let bg = palette.map { UIColor(hex: $0.background) }
        let surface = palette.map { UIColor(hex: $0.surface) }
        let text = palette.map { UIColor(hex: $0.text) }
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = tint
        UITableView.appearance().backgroundColor = bg
        UITableViewCell.appearance().backgroundColor = surface
        UICollectionView.appearance().backgroundColor = bg

        let nav = UINavigationBarAppearance()
        if let bg = bg {
            nav.configureWithOpaqueBackground()
            nav.backgroundColor = bg
            nav.shadowColor = .clear
        } else {
            nav.configureWithDefaultBackground()
        }
        if let text = text {
            nav.titleTextAttributes = [.foregroundColor: text]
            nav.largeTitleTextAttributes = [.foregroundColor: text]
        }
        if monospaced {
            nav.titleTextAttributes[.font] = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            nav.largeTitleTextAttributes[.font] = UIFont.monospacedSystemFont(ofSize: 32, weight: .bold)
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = tint

        let tab = UITabBarAppearance()
        if let bg = bg {
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = bg
        } else {
            tab.configureWithDefaultBackground()
        }
        UITabBar.appearance().standardAppearance = tab
        if #available(iOS 15.0, *) { UITabBar.appearance().scrollEdgeAppearance = tab }
        UITabBar.appearance().tintColor = tint
        UISwitch.appearance().onTintColor = tint
        UISlider.appearance().minimumTrackTintColor = tint
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Тема на корне: акцент, фон экранов на `ScrollView` и шрифт.
struct ThemedRoot: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .accentColor(theme.accent)
            .font(theme.monospaced ? .system(.body, design: .monospaced) : .body)
            .background((theme.palette.map { Color(UIColor(hex: $0.background)) } ?? Color(.systemBackground)).ignoresSafeArea())
    }
}

extension View {
    /// Строка простого списка в цвет фона темы.
    func themedRow() -> some View { listRowBackground(AppTheme.rowBackground) }
}

/// Строки сгруппированного списка в цвете карточек темы. На iOS 16+ списки сделаны на UICollectionView,
/// и `UITableViewCell.appearance()` их не красит — без этого настройки оставались системно-серыми при цветной теме.
struct ThemedRows<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Group { content }.listRowBackground(AppTheme.cardBackground)
    }
}

/// Фон сгруппированного списка — фон темы (iOS 16+; раньше его красил `UITableView.appearance()`).
struct ThemedListBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *), let p = AppTheme.current.palette {
            content.scrollContentBackground(.hidden).background(Color(UIColor(hex: p.background)).ignoresSafeArea())
        } else {
            content
        }
    }
}

extension View {
    func themedList() -> some View { modifier(ThemedListBackground()) }
}

/// Цвет библиотеки (выбранные фишки, закрепления, годы) — цвет основного аккаунта в оттенке темы,
/// как `libraryAccent()` / `ServiceColors.themed` на Android: Spotify зелёный, Яндекс жёлтый, ВК синий; без аккаунта — акцент темы.
enum LibraryAccent {
    static func color(_ source: CatalogSource? = MainAccount.shared.main) -> Color {
        guard let s = source else { return .accentColor }
        let hex: UInt32
        switch (AppTheme.current, s) {
        case (.standard, .SPOTIFY): hex = 0x1ED760
        case (.standard, .YANDEX): hex = 0xFFCC00
        case (.standard, .VK): hex = 0x2787F5
        case (.gruvbox, .SPOTIFY): hex = 0xB8BB26
        case (.gruvbox, .YANDEX): hex = 0xFABD2F
        case (.gruvbox, .VK): hex = 0x83A598
        case (.catppuccin, .SPOTIFY): hex = 0xA6E3A1
        case (.catppuccin, .YANDEX): hex = 0xF9E2AF
        case (.catppuccin, .VK): hex = 0x89B4FA
        case (.synthwave, .SPOTIFY): hex = 0x72F1B8
        case (.synthwave, .YANDEX): hex = 0xFEDE5D
        case (.synthwave, .VK): hex = 0x36F9F6
        case (.sakura, .SPOTIFY): hex = 0x9CCB9A
        case (.sakura, .YANDEX): hex = 0xE8C77A
        case (.sakura, .VK): hex = 0x9DB8E0
        case (.linux, .SPOTIFY): hex = 0x8AE234
        case (.linux, .YANDEX): hex = 0xFCE94F
        case (.linux, .VK): hex = 0x729FCF
        }
        return Color(UIColor(hex: hex))
    }

    /// Текст поверх цвета: чёрный на светлом, белый на тёмном.
    static func onColor(_ source: CatalogSource? = MainAccount.shared.main) -> Color {
        guard source != nil else { return Color(.systemBackground) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color(source)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.45 ? .black : .white
    }
}
