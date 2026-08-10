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
    /// Экран без выреза: виджет открывается от значка в меню-баре.
    case menuBarItem
    /// Экран без выреза и значок неизвестен: кругляш по центру сверху.
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
    /// Насколько зона наведения шире свёрнутого вида с каждой стороны.
    public var hoverInset: CGFloat
    /// Насколько зона наведения свисает ниже выреза.
    ///
    /// Внутри самого выреза курсор не виден — целиться туда неудобно.
    /// Полоска под вырезом попадает в пустую середину меню-бара,
    /// где курсор виден и куда легко попасть движением сверху вниз.
    public var hoverBelowNotch: CGFloat

    public init(
        expandedSize: CGSize = CGSize(width: 720, height: 272),
        syntheticDiameter: CGFloat = 22,
        panelPadding: CGFloat = 24,
        hoverInset: CGFloat = 10,
        hoverBelowNotch: CGFloat = 20
    ) {
        self.expandedSize = expandedSize
        self.syntheticDiameter = syntheticDiameter
        self.panelPadding = panelPadding
        self.hoverInset = hoverInset
        self.hoverBelowNotch = hoverBelowNotch
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

    /// - Parameter anchor: прямоугольник значка в меню-баре. На экранах без
    ///   выреза виджет открывается от него: значок стоит там, куда его
    ///   поставил пользователь, а не по центру верхней кромки.
    public static func layout(
        for screen: ScreenMetrics,
        metrics: NotchMetrics = .default,
        anchor: CGRect? = nil
    ) -> NotchLayout {
        if let collapsed = hardwareNotchRect(for: screen) {
            return makeLayout(kind: .hardware, collapsed: collapsed, screen: screen, metrics: metrics)
        }

        // Значок в меню-баре, если он известен и находится на этом экране.
        if let anchor, screen.frame.intersects(anchor) {
            return makeLayout(kind: .menuBarItem, collapsed: anchor, screen: screen, metrics: metrics)
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
        // Клэмп панели — к экрану, расширенному на `panelPadding`, а не впритык
        // к самому экрану. `expanded` уже прижат к настоящей границе экрана
        // своим собственным клэмпом (см. `expandedRect`) — то есть видимая,
        // интерактивная поверхность виджета никогда не съезжает на соседний
        // монитор. Но если клэмпить панель к той же самой границе, отступ
        // `panelPadding` между этой границей и краем панели на прижатой
        // стороне схлопывается в ноль: `NotchRootView.surfaceRect` рассчитывает
        // на этот отступ, чтобы разместить скруглённые "уши" виджета
        // (`-DS.flare`, 12pt), и без запаса они обрезаются рамкой окна.
        // Сама панель невидима и не интерактивна за пределами `expanded`/
        // `collapsed`, так что немного вылезти за экран ради этого запаса
        // безопасно — как и было для верхнего края с самого начала.
        panel = clampHorizontally(panel, within: screen.frame.insetBy(dx: -metrics.panelPadding, dy: 0))

        // Зона наведения шире и ниже свёрнутого вида: внутри выреза курсор
        // не виден, и попадать туда вслепую неудобно. Полоса под вырезом
        // приходится на пустую середину меню-бара.
        let hoverTop = screen.frame.maxY
        let hoverBottom = max(
            screen.frame.minY,
            collapsed.minY - metrics.hoverBelowNotch
        )
        // В отличие от панели — это интерактивная зона (по ней решается,
        // раскрывать ли виджет), и она обязана оставаться на своём экране:
        // без клэмпа значок меню-бара у самого края мог бы породить зону,
        // цепляющую координаты соседнего монитора в многоэкранной раскладке.
        let hover = clampHorizontally(
            CGRect(
                x: collapsed.minX - metrics.hoverInset,
                y: hoverBottom,
                width: collapsed.width + metrics.hoverInset * 2,
                height: hoverTop - hoverBottom
            ),
            within: screen.frame
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
