import Foundation

/// Состояние управления одним вентилятором: либо автоматика прошивки,
/// либо ручной процент от диапазона оборотов этого конкретного вентилятора.
public enum FanOverride: Sendable, Equatable {
    case auto
    case percent(Int)
}

/// Пересчёт между процентом мощности и оборотами конкретного вентилятора.
///
/// Проценты — не абстракция поверх произвольного диапазона: 0% и 100%
/// всегда упираются в `minRPM`/`maxRPM`, которые сообщает сам вентилятор.
/// Программно попросить оборотов больше паспортного максимума нельзя даже
/// в принципе — контроллер вентилятора сам обрежет по своему пределу,
/// что бы мы ни отправили. Этот пересчёт лишь переводит проценты в RPM
/// для отправки и обратно для отображения.
public enum FanPercent {

    /// Шаг регулятора — пользователь выбирает баланс тишина/охлаждение
    /// ступенями, а не произвольным числом с точностью до оборота.
    public static let step = 5
    public static let minimum = 0
    public static let maximum = 100

    public static func snap(_ percent: Int) -> Int {
        let clamped = min(max(percent, minimum), maximum)
        return (clamped / step) * step
    }

    public static func rpm(forPercent percent: Int, minRPM: Double, maxRPM: Double) -> Double {
        guard maxRPM > minRPM else { return minRPM }
        let fraction = Double(snap(percent)) / 100.0
        return minRPM + (maxRPM - minRPM) * fraction
    }

    public static func percent(forRPM rpm: Double, minRPM: Double, maxRPM: Double) -> Int {
        guard maxRPM > minRPM else { return 0 }
        let fraction = (rpm - minRPM) / (maxRPM - minRPM)
        return snap(Int((fraction * 100).rounded()))
    }
}
