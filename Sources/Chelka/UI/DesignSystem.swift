import AppKit
import SwiftUI

/// Размеры и цвета в одном месте: подбирать вид можно, не трогая логику.
enum DS {
    /// Радиус нижних углов раскрытого виджета.
    static let bottomRadius: CGFloat = 26
    /// Радиус «вывернутых» верхних углов, которыми виджет стекает с края экрана.
    static let flare: CGFloat = 12

    static let contentPadding: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 12

    static let syntheticDiameter: CGFloat = 22
}

enum NotchAnimation {
    /// Одна пружина на все переходы: раскрытие, сворачивание, смена содержимого.
    /// Разные кривые в одном виджете сразу читаются как рассинхрон.
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0)
    static let content = Animation.easeOut(duration: 0.18)
}

extension NSColor {
    /// Поверхность виджета. Динамический цвет — сам следует за appearance окна,
    /// поэтому переключение темы не требует пересборки видов.
    static let notchSurface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.055, alpha: 0.94)
            : NSColor(calibratedWhite: 0.97, alpha: 0.94)
    }

    static let notchCard = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.06)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)
    }

    static let notchStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1.0, alpha: 0.10)
            : NSColor(calibratedWhite: 0.0, alpha: 0.08)
    }
}

extension Color {
    static let notchSurface = Color(nsColor: .notchSurface)
    static let notchCard = Color(nsColor: .notchCard)
    static let notchStroke = Color(nsColor: .notchStroke)
    static let notchPrimary = Color(nsColor: .labelColor)
    static let notchSecondary = Color(nsColor: .secondaryLabelColor)
    static let notchTertiary = Color(nsColor: .tertiaryLabelColor)
}
