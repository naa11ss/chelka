import Foundation

/// Тема оформления виджета. `system` следует за системной настройкой.
public enum AppTheme: String, CaseIterable, Sendable, Codable {
    case system
    case light
    case dark

    public var localizedTitle: String {
        switch self {
        case .system: return String(localized: "theme.system", defaultValue: "Авто")
        case .light: return String(localized: "theme.light", defaultValue: "Светлая")
        case .dark: return String(localized: "theme.dark", defaultValue: "Тёмная")
        }
    }
}
