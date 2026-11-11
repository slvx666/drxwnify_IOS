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
