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

    /// Меньше 0.85 обрезает содержимое карточек (у MetricsCard, например,
    /// фиксированная ширина в 168pt), больше 1.3 — уже не «виджет», а окно.
    static let range: ClosedRange<Double> = 0.85...1.3
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
