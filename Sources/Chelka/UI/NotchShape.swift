import SwiftUI

/// Силуэт виджета: скруглённый низ и «вывернутые» верхние углы,
/// которыми форма плавно перетекает в край экрана — как у Dynamic Island.
///
/// Переданный прямоугольник включает поля под завороты: сама форма занимает
/// `rect`, ужатый на `flare` с боков, а завороты рисуются в этих полях.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat

    func path(in rect: CGRect) -> Path {
        let core = rect.insetBy(dx: flare, dy: 0)
        guard core.width > 0, core.height > 0 else { return Path() }

        let bottom = min(bottomRadius, min(core.width, core.height) / 2)
        let turn = min(flare, core.height / 2)

        var path = Path()

        // Левый заворот: приходим из-за границы и уходим вниз.
        path.move(to: CGPoint(x: core.minX - turn, y: core.minY))
        path.addQuadCurve(
            to: CGPoint(x: core.minX, y: core.minY + turn),
            control: CGPoint(x: core.minX, y: core.minY)
        )

        // Левая стенка и нижний левый угол.
        path.addLine(to: CGPoint(x: core.minX, y: core.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: core.minX + bottom, y: core.maxY),
            control: CGPoint(x: core.minX, y: core.maxY)
        )

        // Дно и нижний правый угол.
        path.addLine(to: CGPoint(x: core.maxX - bottom, y: core.maxY))
        path.addQuadCurve(
            to: CGPoint(x: core.maxX, y: core.maxY - bottom),
            control: CGPoint(x: core.maxX, y: core.maxY)
        )

        // Правая стенка и правый заворот.
        path.addLine(to: CGPoint(x: core.maxX, y: core.minY + turn))
        path.addQuadCurve(
            to: CGPoint(x: core.maxX + turn, y: core.minY),
            control: CGPoint(x: core.maxX, y: core.minY)
        )

        path.closeSubpath()
        return path
    }
}
