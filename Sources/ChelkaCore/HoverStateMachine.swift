import Foundation

/// Монотонные часы приложения. Не идут назад при синхронизации системного
/// времени и держат малый порядок величин, поэтому пригодны для точных задержек.
public enum MonotonicClock {
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Состояние виджета.
public enum NotchState: Sendable, Equatable {
    case collapsed
    case expanded
}

/// Задержки раскрытия/сворачивания. Без них виджет мигает,
/// когда курсор проходит мимо выреза к меню-бару.
public struct HoverPolicy: Sendable, Equatable {
    public var openDelay: TimeInterval
    public var closeDelay: TimeInterval

    public init(openDelay: TimeInterval = 0.25, closeDelay: TimeInterval = 0.4) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    public static let `default` = HoverPolicy()
}

/// Чистая машина состояний наведения: решает, когда раскрыться и когда свернуться.
///
/// Времени сама не знает — его передают снаружи. Поэтому логика дребезга
/// проверяется тестами за миллисекунды, без мыши и без экрана.
///
/// Время — монотонная метка в секундах (`ProcessInfo.systemUptime`), не `Date`.
/// Причины две: `Date` прыгает при синхронизации часов и подвесил бы виджет
/// раскрытым, и на его порядке величин double теряет ~2·10⁻⁸ с — этого хватает,
/// чтобы сравнение с порогом задержки срабатывало не всегда.
public struct HoverStateMachine: Sendable, Equatable {
    public private(set) var state: NotchState
    public private(set) var policy: HoverPolicy

    /// Закреплённое раскрытие: открыли хоткеем — курсор больше не решает.
    public private(set) var isPinned: Bool = false

    /// Момент, с которого условие для смены состояния держится непрерывно.
    private var pendingSince: TimeInterval?
    private var pendingTarget: NotchState?

    public init(state: NotchState = .collapsed, policy: HoverPolicy = .default) {
        self.state = state
        self.policy = policy
    }

    /// Допуск сравнения времени: одна микросекунда.
    ///
    /// Разность двух double-меток промахивается мимо порога на ~2·10⁻¹⁴
    /// (`1000.4 - 1000 == 0.39999999999997726`). Без допуска переход
    /// не срабатывает на «ровных» интервалах и виджет залипает.
    /// Микросекунда неощутима для человека и на 8 порядков больше шума.
    static let timeEpsilon: TimeInterval = 1e-6

    /// Есть ли отложенный переход — по этому флагу UI решает, крутить ли таймер.
    public var hasPendingTransition: Bool { pendingTarget != nil }

    /// Сообщает машине текущее положение курсора и текущую монотонную метку.
    /// Возвращает актуальное состояние.
    @discardableResult
    public mutating func update(inside: Bool, now: TimeInterval) -> NotchState {
        guard !isPinned else {
            pendingSince = nil
            pendingTarget = nil
            return state
        }

        let desired: NotchState = inside ? .expanded : .collapsed

        guard desired != state else {
            // Условие вернулось к текущему состоянию — отложенный переход отменяется.
            pendingSince = nil
            pendingTarget = nil
            return state
        }

        if pendingTarget != desired {
            pendingTarget = desired
            pendingSince = now
            return state
        }

        let delay = desired == .expanded ? policy.openDelay : policy.closeDelay
        if let since = pendingSince, now - since >= delay - Self.timeEpsilon {
            state = desired
            pendingSince = nil
            pendingTarget = nil
        }
        return state
    }

    /// Открыть принудительно (хоткей). Курсор перестаёт управлять состоянием.
    public mutating func pinOpen() {
        isPinned = true
        state = .expanded
        pendingSince = nil
        pendingTarget = nil
    }

    /// Снять закрепление. Дальше состояние снова решает курсор.
    public mutating func unpin(inside: Bool, now: TimeInterval) {
        isPinned = false
        pendingSince = nil
        pendingTarget = nil
        update(inside: inside, now: now)
    }

    /// Мгновенно свернуть (Esc, клик мимо).
    public mutating func forceCollapse() {
        isPinned = false
        state = .collapsed
        pendingSince = nil
        pendingTarget = nil
    }
}
