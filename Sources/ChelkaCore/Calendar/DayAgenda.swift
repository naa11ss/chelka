import Foundation

/// Одна встреча из календаря.
public struct AgendaEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Цвет календаря, к которому относится встреча — в виджете он
    /// единственное, что отличает рабочее от личного.
    public let colorHex: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        colorHex: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.colorHex = colorHex
    }

    public func isRunning(at moment: Date) -> Bool {
        !isAllDay && start <= moment && moment < end
    }

    public func isOver(at moment: Date) -> Bool {
        !isAllDay && end <= moment
    }
}

/// Правила показа сегодняшнего дня.
///
/// Вынесено из EventKit намеренно: «что показать первым», «что уже прошло»,
/// «сколько осталось» — то, что должно быть предсказуемым и проверяться
/// без обращения к настоящему календарю пользователя.
public enum DayAgenda {

    /// Порядок показа: сначала идущее сейчас, потом ближайшее, потом
    /// остальное будущее, и только в самом конце — прошедшее.
    ///
    /// Виджет узкий, и первое, что попадает на глаза, должно отвечать на
    /// вопрос «что у меня прямо сейчас», а не «что было утром».
    public static func ordered(_ events: [AgendaEvent], now: Date) -> [AgendaEvent] {
        events.sorted { lhs, rhs in
            let lhsRank = rank(lhs, now: now)
            let rhsRank = rank(rhs, now: now)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            // Внутри группы — по времени начала; прошедшее наоборот,
            // чтобы ближайшее к настоящему было ближе к началу списка.
            return lhsRank == 3 ? lhs.start > rhs.start : lhs.start < rhs.start
        }
    }

    private static func rank(_ event: AgendaEvent, now: Date) -> Int {
        if event.isRunning(at: now) { return 0 }
        if event.isAllDay { return 1 }
        if !event.isOver(at: now) { return 2 }
        return 3
    }

    /// Что идёт прямо сейчас — если такое есть.
    public static func current(_ events: [AgendaEvent], now: Date) -> AgendaEvent? {
        events.first { $0.isRunning(at: now) }
    }

    /// Ближайшее из ещё не начавшихся.
    public static func next(_ events: [AgendaEvent], now: Date) -> AgendaEvent? {
        events
            .filter { !$0.isAllDay && $0.start > now }
            .min { $0.start < $1.start }
    }

    /// Сколько осталось до начала — короткой строкой для подписи.
    ///
    /// Отрицательный и слишком далёкий интервалы отсекаются: «через
    /// −5 минут» бессмысленно, а «через 9 часов» на сегодняшней повестке
    /// не встречается, потому что список и так только на сегодня.
    public static func startsIn(_ event: AgendaEvent, now: Date) -> String? {
        let seconds = event.start.timeIntervalSince(now)
        guard seconds > 0 else { return nil }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return T("agenda.now", "вот-вот") }
        if minutes < 60 { return String(format: T("agenda.inMinutes", "через %d мин"), minutes) }

        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? String(format: T("agenda.inHours", "через %d ч"), hours)
            : String(format: T("agenda.inHoursMinutes", "через %d ч %d мин"), hours, rest)
    }
}
