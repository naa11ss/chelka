import AppKit
import Combine
import ChelkaCore

/// Хранит выбранную тему и переводит её в `NSAppearance` для окна.
/// Окно-панель ставит appearance у себя, а SwiftUI наследует её автоматически —
/// поэтому материалы и системные цвета всегда совпадают с выбранной темой.
final class ThemeController: ObservableObject {
    private static let defaultsKey = "chelka.theme"

    @Published private(set) var theme: AppTheme

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.defaultsKey) ?? AppTheme.system.rawValue
        self.theme = AppTheme(rawValue: raw) ?? .system
    }

    private let defaults: UserDefaults

    func set(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        defaults.set(theme.rawValue, forKey: Self.defaultsKey)
        Log.app.info("тема переключена на \(theme.rawValue, privacy: .public)")
    }

    /// `nil` означает «следовать за системой».
    var appearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
