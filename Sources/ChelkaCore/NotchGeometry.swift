import CoreGraphics
import Foundation

/// Снимок параметров экрана, снятый с `NSScreen`, но без зависимости от AppKit.
/// Благодаря этому вся геометрия выреза считается и тестируется без запуска UI.
///
/// Система координат — глобальная кокоа-система: начало внизу слева, ось Y вверх.
public struct ScreenMetrics: Sendable, Equatable {
    /// Полный фрейм экрана в глобальных координатах.
    public let frame: CGRect
    /// Высота безопасной зоны сверху. > 0 только на экранах с аппаратным вырезом.
    public let safeAreaTop: CGFloat
    /// Ширина области слева от выреза (`NSScreen.auxiliaryTopLeftArea`).
    public let auxiliaryLeftWidth: CGFloat?
    /// Ширина области справа от выреза (`NSScreen.auxiliaryTopRightArea`).
    public let auxiliaryRightWidth: CGFloat?
    /// Толщина меню-бара, нужна для позиционирования кругляша на экранах без выреза.
    public let menuBarHeight: CGFloat

    public init(
        frame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?,
        menuBarHeight: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
        self.menuBarHeight = menuBarHeight
    }
}

/// Чем прикидывается свёрнутое состояние на конкретном экране.
public enum NotchKind: Sendable, Equatable {
    /// Аппаратный вырез: свёрнутый вид невидим, работает только зона наведения.
    case hardware
    /// Экран без выреза: рисуем видимый кругляш по центру сверху.
    case synthetic
}

/// Константы раскладки. Вынесены отдельно, чтобы подбирать размеры,
/// не трогая логику, и чтобы тесты не зависели от «магических чисел».
public struct NotchMetrics: Sendable, Equatable {
    public var expandedSize: CGSize
    /// Диаметр кругляша на экранах без выреза.
    public var syntheticDiameter: CGFloat
    /// Отступ панели от краёв экрана — запас под тень и анимацию.
    public var panelPadding: CGFloat
    /// Насколько расширяется зона наведения вокруг свёрнутого вида.
    public var hoverInset: CGFloat

    public init(
        expandedSize: CGSize = CGSize(width: 720, height: 272),
        syntheticDiameter: CGFloat = 22,
        panelPadding: CGFloat = 24,
        hoverInset: CGFloat = 4
    ) {
        self.expandedSize = expandedSize
        self.syntheticDiameter = syntheticDiameter
        self.panelPadding = panelPadding
        self.hoverInset = hoverInset
    }

    public static let `default` = NotchMetrics()
}

/// Готовая раскладка для одного экрана: где стоит окно-панель и какие
/// прямоугольники занимает свёрнутое и раскрытое состояние.
///
/// `*Screen` — глобальные координаты (для позиционирования окна и hit-теста мыши).
/// `*InView` — координаты внутри панели, начало внизу слева (AppKit).
/// `*InSwiftUI` — координаты внутри панели, начало вверху слева (SwiftUI).
public struct NotchLayout: Sendable, Equatable {
    public let kind: NotchKind
    public let panelFrame: CGRect
    public let collapsedRectScreen: CGRect
    public let expandedRectScreen: CGRect
    /// Зона, при попадании в которую виджет раскрывается.
    public let hoverRectScreen: CGRect

    public init(
        kind: NotchKind,
        panelFrame: CGRect,
        collapsedRectScreen: CGRect,
        expandedRectScreen: CGRect,
        hoverRectScreen: CGRect
    ) {
        self.kind = kind
        self.panelFrame = panelFrame
        self.collapsedRectScreen = collapsedRectScreen
        self.expandedRectScreen = expandedRectScreen
        self.hoverRectScreen = hoverRectScreen
    }

    public var collapsedRectInView: CGRect { NotchLayout.toView(collapsedRectScreen, panel: panelFrame) }
    public var expandedRectInView: CGRect { NotchLayout.toView(expandedRectScreen, panel: panelFrame) }
    public var hoverRectInView: CGRect { NotchLayout.toView(hoverRectScreen, panel: panelFrame) }

    public var collapsedRectInSwiftUI: CGRect { NotchLayout.toSwiftUI(collapsedRectScreen, panel: panelFrame) }
    public var expandedRectInSwiftUI: CGRect { NotchLayout.toSwiftUI(expandedRectScreen, panel: panelFrame) }

    static func toView(_ rect: CGRect, panel: CGRect) -> CGRect {
        rect.offsetBy(dx: -panel.minX, dy: -panel.minY)
    }

    static func toSwiftUI(_ rect: CGRect, panel: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - panel.minX,
            y: panel.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Считает раскладку по параметрам экрана. Никаких захардкоженных пикселей
/// вырезов конкретных моделей — только то, что сообщила система.
public enum NotchGeometry {

    public static func layout(for screen: ScreenMetrics, metrics: NotchMetrics = .default) -> NotchLayout {
        if let collapsed = hardwareNotchRect(for: screen) {
            return makeLayout(kind: .hardware, collapsed: collapsed, screen: screen, metrics: metrics)
        }
        return makeLayout(
            kind: .synthetic,
            collapsed: syntheticRect(for: screen, metrics: metrics),
            screen: screen,
            metrics: metrics
        )
    }

    /// Прямоугольник аппаратного выреза или `nil`, если выреза нет.
    ///
    /// Вырез = ширина экрана минус две вспомогательные области по бокам.
    /// Обе области обязаны быть заданы и в сумме быть уже экрана —
    /// иначе система говорит, что выреза нет.
    static func hardwareNotchRect(for screen: ScreenMetrics) -> CGRect? {
        guard screen.safeAreaTop > 0 else { return nil }
        guard let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth else { return nil }
        guard left > 0, right > 0 else { return nil }

        let width = screen.frame.width - left - right
        guard width > 0 else { return nil }

        return CGRect(
            x: screen.frame.minX + left,
            y: screen.frame.maxY - screen.safeAreaTop,
            width: width,
            height: screen.safeAreaTop
        )
    }

    /// Кругляш по центру верхнего края для экранов без выреза.
    static func syntheticRect(for screen: ScreenMetrics, metrics: NotchMetrics) -> CGRect {
        let d = metrics.syntheticDiameter
        let barHeight = max(screen.menuBarHeight, d)
        let y = screen.frame.maxY - barHeight + (barHeight - d) / 2
        return CGRect(x: screen.frame.midX - d / 2, y: y, width: d, height: d)
    }

    private static func makeLayout(
        kind: NotchKind,
        collapsed: CGRect,
        screen: ScreenMetrics,
        metrics: NotchMetrics
    ) -> NotchLayout {
        let expanded = expandedRect(anchoredTo: collapsed, screen: screen, metrics: metrics)

        // Панель обязана вмещать оба состояния плюс запас на тень.
        let union = collapsed.union(expanded)
        var panel = union.insetBy(dx: -metrics.panelPadding, dy: -metrics.panelPadding)
        // Сверху расти некуда — край экрана.
        panel = CGRect(
            x: panel.minX,
            y: panel.minY,
            width: panel.width,
            height: screen.frame.maxY - panel.minY
        )
        panel = clampHorizontally(panel, within: screen.frame)

        // Зона наведения: свёрнутый вид плюс небольшой запас,
        // растянутый до самого верха экрана (мышь у края не «проваливается»).
        let hover = CGRect(
            x: collapsed.minX - metrics.hoverInset,
            y: collapsed.minY,
            width: collapsed.width + metrics.hoverInset * 2,
            height: screen.frame.maxY - collapsed.minY
        )

        return NotchLayout(
            kind: kind,
            panelFrame: panel,
            collapsedRectScreen: collapsed,
            expandedRectScreen: expanded,
            hoverRectScreen: hover
        )
    }

    /// Раскрытое состояние: прижато к верхнему краю, отцентровано по вырезу,
    /// но не вылезает за экран.
    static func expandedRect(anchoredTo collapsed: CGRect, screen: ScreenMetrics, metrics: NotchMetrics) -> CGRect {
        let width = min(metrics.expandedSize.width, screen.frame.width - metrics.panelPadding * 2)
        let height = min(metrics.expandedSize.height, screen.frame.height - metrics.panelPadding)

        var rect = CGRect(
            x: collapsed.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        rect = clampHorizontally(rect, within: screen.frame)
        return rect
    }

    static func clampHorizontally(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        var result = rect
        if result.width >= bounds.width {
            result.origin.x = bounds.minX
            result.size.width = bounds.width
        } else if result.minX < bounds.minX {
            result.origin.x = bounds.minX
        } else if result.maxX > bounds.maxX {
            result.origin.x = bounds.maxX - result.width
        }
        return result
    }
}
