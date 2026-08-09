import AppKit
import ChelkaCore

extension NSScreen {
    /// Снимает параметры экрана в чистую структуру ядра.
    /// Всё, что знает о вырезе, приходит от системы — никаких таблиц моделей.
    var chelkaMetrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryLeftWidth: auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: auxiliaryTopRightArea?.width,
            menuBarHeight: NSStatusBar.system.thickness
        )
    }

    var hasHardwareNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Экран, на котором живёт виджет: встроенный с вырезом, иначе основной.
    static var chelkaTarget: NSScreen? {
        screens.first(where: \.hasHardwareNotch) ?? screens.first ?? main
    }
}
