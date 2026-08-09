import Foundation

/// Тема оформления виджета. `system` следует за системной настройкой.
public enum AppTheme: String, CaseIterable, Sendable, Codable {
    case system
    case light
    case dark

    public var localizedTitle: String {
        switch self {
        case .system: return T("theme.system", "Авто")
        case .light: return T("theme.light", "Светлая")
        case .dark: return T("theme.dark", "Тёмная")
        }
    }
}
