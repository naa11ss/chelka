import AppKit

/// Корневой вид панели, пропускающий клики сквозь себя.
///
/// Панель заведомо больше видимого виджета — иначе анимации некуда расти.
/// Без этого класса прозрачные поля панели воровали бы клики у приложений
/// под ними: пользователь целится в меню-бар, а попадает в невидимое окно.
final class PassThroughContentView: NSView {

    /// Прямоугольник, внутри которого вид реально принимает события.
    /// Координаты — этого вида (AppKit, начало внизу слева).
    var interactiveRect: CGRect = .zero {
        didSet {
            guard interactiveRect != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Для contentView система передаёт точку в координатах окна.
        let local = convert(point, from: nil)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
