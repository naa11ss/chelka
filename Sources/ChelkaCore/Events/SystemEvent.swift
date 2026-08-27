import Foundation

/// Короткое сообщение, которое виджет показывает прямо в вырезе,
/// не раскрываясь целиком.
public struct SystemEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case battery
        case power
        case network
    }

    public let id: UUID
    public let kind: Kind
    /// Имя символа SF — слева от текста.
    public let symbol: String
    public let title: String
    /// Правая часть строки: процент, имя сети. `nil` — сообщение и так целое.
    public let detail: String?
    public let occurredAt: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: Kind,
        symbol: String,
        title: String,
        detail: String? = nil,
        occurredAt: TimeInterval
    ) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// Состояние питания, каким его отдаёт система.
public struct PowerState: Sendable, Equatable {
    public let percent: Int
    public let isPlugged: Bool
    /// `nil` на машинах без встроенной батареи (Mac mini, Mac Studio).
    public let hasBattery: Bool

    public init(percent: Int, isPlugged: Bool, hasBattery: Bool) {
        self.percent = percent
        self.isPlugged = isPlugged
        self.hasBattery = hasBattery
    }
}

/// Решает, о чём стоит сообщить, а о чём молчать.
///
/// Вынесено из монитора намеренно: «сообщать один раз на пересечение
/// порога, а не на каждый тик» — ровно то место, где легко получить
/// назойливый виджет, и ровно то, что проверяется тестами без железа.
public struct SystemEventRules: Sendable, Equatable {

    /// Пороги разряда, о которых стоит сказать.
    ///
    /// Когда за один шаг пройдено сразу несколько (25% → 8% пересекает и 20,
    /// и 10), сообщать надо про самый нижний: он тревожнее, и говорить
    /// «осталось 20%», когда осталось 8%, — прямая дезинформация.
    public static let batteryThresholds = [20, 10, 5]

    private var lastPower: PowerState?

    public init() {}

    /// Событие о питании, если оно того стоит.
    ///
    /// Молчит, пока ничего содержательного не произошло: процент, ползущий
    /// вниз между порогами, — не новость, а вот пересечение порога,
    /// подключение и отключение адаптера — новость.
    public mutating func onPower(_ state: PowerState, now: TimeInterval) -> SystemEvent? {
        defer { lastPower = state }
        guard state.hasBattery else { return nil }
        guard let previous = lastPower else { return nil }

        if previous.isPlugged != state.isPlugged {
            return SystemEvent(
                kind: .power,
                symbol: state.isPlugged ? "bolt.fill" : "battery.50",
                title: state.isPlugged
                    ? T("event.power.plugged", "Зарядка")
                    : T("event.power.unplugged", "От батареи"),
                detail: "\(state.percent)%",
                occurredAt: now
            )
        }

        // Пороги — только на разряде: то же число на зарядке означает
        // ровно противоположное и пугать им незачем.
        guard !state.isPlugged, state.percent < previous.percent else { return nil }

        // `.last`, а не `.first`: пороги перечислены по убыванию, и за один
        // шаг их может быть пройдено несколько — нужен самый нижний.
        guard let crossed = Self.batteryThresholds.last(where: { previous.percent > $0 && state.percent <= $0 }) else {
            return nil
        }

        return SystemEvent(
            kind: .battery,
            symbol: crossed <= 10 ? "battery.25" : "battery.50",
            title: T("event.battery.low", "Заряд на исходе"),
            detail: "\(state.percent)%",
            occurredAt: now
        )
    }

    private var lastOnline: Bool?

    /// Событие о сети. Первое состояние запоминается молча — сообщать
    /// «сеть есть» сразу после запуска приложения незачем.
    public mutating func onNetwork(isOnline: Bool, interface: String?, now: TimeInterval) -> SystemEvent? {
        defer { lastOnline = isOnline }
        guard let previous = lastOnline, previous != isOnline else { return nil }

        return SystemEvent(
            kind: .network,
            symbol: isOnline ? "wifi" : "wifi.slash",
            title: isOnline
                ? T("event.network.online", "Сеть есть")
                : T("event.network.offline", "Нет сети"),
            detail: isOnline ? interface : nil,
            occurredAt: now
        )
    }
}
