import AppKit
import Combine
import EventKit
import ChelkaCore

/// Сегодняшние встречи из настоящего Календаря.
///
/// EventKit — публичный фреймворк, тот же, которым пользуется сам Календарь:
/// виджет не выдумывает свой список дел, а показывает то, что у пользователя
/// уже есть, включая события, заведённые через Siri или прилетевшие с iPhone.
///
/// Доступ спрашивается не при запуске, а при первом раскрытии вкладки «День»:
/// выпрашивать календарь у того, кто про эту вкладку и не знает, незачем.
@MainActor
final class CalendarService: ObservableObject {

    enum Access: Equatable {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var access: Access = .unknown

    private let store = EKEventStore()
    private var timer: Timer?
    private var didRequestAccess = false
    private var changeObserver: NSObjectProtocol?

    /// Список пересобирается нечасто: встречи не меняются ежесекундно,
    /// а подписка на `EKEventStoreChanged` ловит правки сразу.
    private static let refreshInterval: TimeInterval = 300

    init() {
        access = Self.currentAccess()
    }

    deinit {
        timer?.invalidate()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    var isPolling: Bool { timer != nil }

    // MARK: - Жизненный цикл

    /// Вызывается, когда пользователь открыл вкладку «День».
    func activate() {
        requestAccessIfNeeded()
        guard timer == nil else { return }

        reload()

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Правку в Календаре видно сразу, без ожидания следующего круга.
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Доступ

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        case .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    private func requestAccessIfNeeded() {
        access = Self.currentAccess()
        guard access == .unknown, !didRequestAccess else { return }
        didRequestAccess = true

        store.requestFullAccessToEvents { [weak self] granted, error in
            if let error {
                Log.app.error("календарь: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in
                guard let self else { return }
                self.access = granted ? .granted : .denied
                if granted { self.reload() }
            }
        }
    }

    // MARK: - Чтение

    private func reload() {
        guard Self.currentAccess() == .granted else {
            access = Self.currentAccess()
            events = []
            return
        }
        access = .granted

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let fetched = store.events(matching: predicate)
            // Отклонённые встречи в повестке не нужны: пользователь уже
            // сказал, что не придёт, и место в узком виджете они занимают зря.
            .filter { $0.status != .canceled }
            .map { event in
                AgendaEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? T("agenda.untitled", "Без названия"),
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    colorHex: event.calendar?.color.flatMap(Self.hex(from:))
                )
            }

        events = DayAgenda.ordered(fetched, now: Date())
    }

    /// Цвет календаря приходит как `NSColor`; в модели ядра AppKit быть
    /// не может, поэтому переводим в строку и обратно уже в интерфейсе.
    private nonisolated static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
