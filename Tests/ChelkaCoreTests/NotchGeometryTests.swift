import CoreGraphics
import Foundation
import Testing

@testable import ChelkaCore

// Реальные параметры MacBook Air M2 (1470×956 pt, вырез 32 pt).
private let airM2 = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
    safeAreaTop: 32,
    auxiliaryLeftWidth: 651,
    auxiliaryRightWidth: 651,
    menuBarHeight: 24
)

// Внешний монитор без выреза, стоящий справа от встроенного.
private let externalDisplay = ScreenMetrics(
    frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
    safeAreaTop: 0,
    auxiliaryLeftWidth: nil,
    auxiliaryRightWidth: nil,
    menuBarHeight: 24
)

@Suite("Геометрия выреза")
struct NotchGeometryTests {

    @Test("Аппаратный вырез определяется по вспомогательным областям")
    func detectsHardwareNotch() {
        let layout = NotchGeometry.layout(for: airM2)

        #expect(layout.kind == .hardware)
        #expect(layout.collapsedRectScreen.width == CGFloat(168))
        #expect(layout.collapsedRectScreen.height == CGFloat(32))
        // Прижат к верхнему краю экрана.
        #expect(layout.collapsedRectScreen.maxY == CGFloat(956))
        // Отцентрован по экрану.
        #expect(layout.collapsedRectScreen.midX == CGFloat(735))
    }

    @Test("Экран без выреза получает кругляш по центру верха")
    func fallsBackToSyntheticCircle() {
        let layout = NotchGeometry.layout(for: externalDisplay)

        #expect(layout.kind == .synthetic)
        #expect(layout.collapsedRectScreen.width == NotchMetrics.default.syntheticDiameter)
        #expect(layout.collapsedRectScreen.height == NotchMetrics.default.syntheticDiameter)
        #expect(layout.collapsedRectScreen.midX == externalDisplay.frame.midX)
        // Внутри полосы меню-бара, не выше верхнего края.
        #expect(layout.collapsedRectScreen.maxY <= externalDisplay.frame.maxY)
        #expect(layout.collapsedRectScreen.minY >= externalDisplay.frame.maxY - externalDisplay.menuBarHeight)
    }

    @Test("safeAreaTop без вспомогательных областей вырезом не считается")
    func requiresAuxiliaryAreas() {
        let weird = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            safeAreaTop: 32,
            auxiliaryLeftWidth: nil,
            auxiliaryRightWidth: nil,
            menuBarHeight: 24
        )
        #expect(NotchGeometry.hardwareNotchRect(for: weird) == nil)
        #expect(NotchGeometry.layout(for: weird).kind == .synthetic)
    }

    @Test("Раскрытое состояние прижато к верху и не выходит за экран")
    func expandedStaysOnScreen() {
        for screen in [airM2, externalDisplay] {
            let layout = NotchGeometry.layout(for: screen)
            let expanded = layout.expandedRectScreen

            #expect(expanded.maxY == screen.frame.maxY)
            #expect(expanded.minX >= screen.frame.minX)
            #expect(expanded.maxX <= screen.frame.maxX)
        }
    }

    @Test("Узкий экран не приводит к панели шире экрана")
    func clampsOnNarrowScreen() {
        let narrow = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 480, height: 320),
            safeAreaTop: 0,
            auxiliaryLeftWidth: nil,
            auxiliaryRightWidth: nil,
            menuBarHeight: 24
        )
        let layout = NotchGeometry.layout(for: narrow)

        #expect(layout.panelFrame.width <= narrow.frame.width)
        #expect(layout.panelFrame.minX >= narrow.frame.minX)
        #expect(layout.panelFrame.maxX <= narrow.frame.maxX)
        #expect(layout.expandedRectScreen.width <= narrow.frame.width)
    }

    @Test("Панель вмещает оба состояния целиком")
    func panelContainsBothStates() {
        for screen in [airM2, externalDisplay] {
            let layout = NotchGeometry.layout(for: screen)

            #expect(layout.panelFrame.contains(layout.collapsedRectScreen))
            #expect(layout.panelFrame.contains(layout.expandedRectScreen))
            #expect(layout.panelFrame.maxY == screen.frame.maxY)
        }
    }

    @Test("Зона наведения покрывает свёрнутый вид и доходит до края экрана")
    func hoverRectReachesScreenEdge() {
        let layout = NotchGeometry.layout(for: airM2)

        #expect(layout.hoverRectScreen.contains(layout.collapsedRectScreen))
        #expect(layout.hoverRectScreen.maxY == airM2.frame.maxY)
    }

    @Test("Работает на экране со смещённым началом координат")
    func handlesOffsetScreenOrigin() {
        let layout = NotchGeometry.layout(for: externalDisplay)

        #expect(layout.collapsedRectScreen.minX > 1470)
        #expect(layout.panelFrame.minX >= 1470)
        #expect(layout.panelFrame.maxX <= 1470 + 2560)
    }
}

@Suite("Перевод координат панели")
struct NotchLayoutCoordinateTests {

    @Test("AppKit-координаты отсчитываются от левого нижнего угла панели")
    func convertsToViewSpace() {
        let layout = NotchGeometry.layout(for: airM2)
        let inView = layout.collapsedRectInView

        #expect(inView.minX == layout.collapsedRectScreen.minX - layout.panelFrame.minX)
        #expect(inView.minY == layout.collapsedRectScreen.minY - layout.panelFrame.minY)
        #expect(inView.size == layout.collapsedRectScreen.size)
        #expect(inView.minX >= 0)
        #expect(inView.minY >= 0)
    }

    @Test("SwiftUI-координаты отсчитываются от левого верхнего угла панели")
    func convertsToSwiftUISpace() {
        let layout = NotchGeometry.layout(for: airM2)
        let inSwiftUI = layout.collapsedRectInSwiftUI

        #expect(inSwiftUI.minX == layout.collapsedRectScreen.minX - layout.panelFrame.minX)
        #expect(inSwiftUI.minY == layout.panelFrame.maxY - layout.collapsedRectScreen.maxY)
        #expect(inSwiftUI.size == layout.collapsedRectScreen.size)
        #expect(inSwiftUI.minY >= 0)
    }

    @Test("Раскрытое состояние в SwiftUI начинается от верхнего края панели минус отступ")
    func expandedSwiftUIOrigin() {
        let layout = NotchGeometry.layout(for: airM2)
        let expanded = layout.expandedRectInSwiftUI

        #expect(expanded.minY == layout.panelFrame.maxY - layout.expandedRectScreen.maxY)
        #expect(expanded.minY >= 0)
        #expect(expanded.maxY <= layout.panelFrame.height)
    }
}
