import Combine
import Foundation
import ChelkaCore

/// Хранит выбранный пользователем масштаб виджета.
///
/// Масштабирует только геометрию (раскрытый размер, кругляш на экранах без
/// выреза) — размер шрифта в карточках нигде от этого множителя не зависит
/// и не может уменьшиться: тексты в интерфейсе и так на грани читаемости.
final class WidgetSizeController: ObservableObject {
    private static let defaultsKey = "chelka.widgetScale"

    /// Нижняя граница — 1.0, не меньше: `ExpandedContentView` вычисляет
    /// раскладку карточек с фиксированными (не масштабируемыми) отступами
    /// и минимальной высотой строки метрик/музыки (`minHeight: 78`) — при
    /// уменьшении общей поверхности эта фиксированная стоимость съедает
    /// непропорционально много места, и ленте буфера снизу не хватает
    /// высоты для подвала с кнопками закрепления/удаления: они рисуются,
    /// но перестают принимать клики (проверено на реальном железе —
    /// работает на 100% и выше, ломается на всём, что меньше). Поднимать
    /// содержимое до масштаба виджета — отдельная задача (проброс scale
    /// в SwiftUI-слой и умножение на него самих отступов/минимумов,
    /// не только внешнего размера панели), пока не сделана. Больше 1.3 —
    /// уже не «виджет», а окно.
    static let range: ClosedRange<Double> = 1.0...1.3
    static let defaultScale: Double = 1.0

    @Published private(set) var scale: Double

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.defaultsKey) as? Double ?? Self.defaultScale
        self.scale = Self.range.contains(stored) ? stored : Self.defaultScale
    }

    func set(_ scale: Double) {
        let clamped = min(max(scale, Self.range.lowerBound), Self.range.upperBound)
        guard clamped != self.scale else { return }
        self.scale = clamped
        defaults.set(clamped, forKey: Self.defaultsKey)
        Log.app.info("размер виджета: \(clamped, format: .fixed(precision: 2))")
    }

    func reset() {
        set(Self.defaultScale)
    }

    /// Раскладка виджета от текущего масштаба — единственное место, где
    /// множитель применяется к конкретным числам.
    var metrics: NotchMetrics {
        let base = NotchMetrics.default
        return NotchMetrics(
            expandedSize: CGSize(width: base.expandedSize.width * scale, height: base.expandedSize.height * scale),
            syntheticDiameter: base.syntheticDiameter * scale,
            panelPadding: base.panelPadding,
            hoverInset: base.hoverInset,
            hoverBelowNotch: base.hoverBelowNotch
        )
    }
}
