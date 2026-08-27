import AppKit
import Combine
import IOKit.ps
import Network
import ChelkaCore

/// Следит за питанием и сетью и превращает изменения в короткие события
/// для выреза.
///
/// В отличие от метрик, этот монитор работает всегда, а не только пока
/// виджет раскрыт: смысл события в том, чтобы сообщить о том, чего
/// пользователь не видел. Стоит он при этом почти ничего — система сама
/// будит нас на изменение, опроса по таймеру здесь нет.
@MainActor
final class SystemEventMonitor: ObservableObject {

    /// Событие, которое сейчас стоит показать. `nil` — показывать нечего.
    @Published private(set) var current: SystemEvent?

    /// Сколько событие висит в вырезе. Достаточно, чтобы прочитать
    /// пять слов, и мало, чтобы надоесть.
    private static let visibleFor: TimeInterval = 4

    private var rules = SystemEventRules()
    private var hideWorkItem: DispatchWorkItem?

    private var powerSource: CFRunLoopSource?
    private let pathMonitor = NWPathMonitor()
    private let bluetooth = BluetoothConnectionWatcher()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        startPowerWatch()
        startNetworkWatch()
        startDeviceWatch()

        Log.app.debug("монитор событий запущен")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        pathMonitor.cancel()
        bluetooth.stop()
        hideWorkItem?.cancel()
        current = nil
    }

    // MARK: - Подключение устройств

    /// Опрашивать `system_profiler` по таймеру круглые сутки ради наушников
    /// нельзя — запуск процесса стоит секунду с лишним. Поэтому идём за
    /// раскладом заряда только когда система сама сказала, что что-то
    /// подключилось.
    private func startDeviceWatch() {
        // Первый список запоминается молча, чтобы уже подключённые
        // устройства не породили плашку при запуске приложения.
        readDevices(announce: false)

        bluetooth.onConnect = { [weak self] in
            // Заряд появляется в system_profiler не мгновенно: сразу после
            // подключения устройство ещё успевает договориться с системой.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { self?.readDevices(announce: true) }
            }
        }
        bluetooth.start()
    }

    private func readDevices(announce: Bool) {
        Task.detached(priority: .utility) {
            let devices = DeviceBatteryReader.readNow()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let event = self.rules.onDevices(devices, now: MonotonicClock.now) else { return }
                guard announce else { return }
                self.show(event)
            }
        }
    }

    // MARK: - Питание

    private func startPowerWatch() {
        // Первое чтение — чтобы правила знали точку отсчёта и не сообщили
        // о «смене» состояния сразу после запуска.
        readPower()

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.readPower() }
        }, context)?.takeRetainedValue() else {
            Log.app.debug("не удалось подписаться на изменения питания")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func readPower() {
        guard let state = Self.currentPowerState() else { return }
        guard let event = rules.onPower(state, now: MonotonicClock.now) else { return }
        show(event)
    }

    /// Публичный IOKit: `IOPSCopyPowerSourcesInfo` — то же самое, чем
    /// пользуется сам индикатор батареи в меню-баре.
    static func currentPowerState() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType
            else { continue }

            let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = description[kIOPSPowerSourceStateKey] as? String

            let percent = max > 0 ? Int((Double(capacity) / Double(max) * 100).rounded()) : 0
            return PowerState(
                percent: percent,
                isPlugged: state == kIOPSACPowerValue,
                hasBattery: true
            )
        }

        // Внутренней батареи нет — стационарный Mac.
        return PowerState(percent: 100, isPlugged: true, hasBattery: false)
    }

    // MARK: - Сеть

    private func startNetworkWatch() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interface = Self.name(for: path)
            Task { @MainActor in
                guard let self else { return }
                guard let event = self.rules.onNetwork(isOnline: online, interface: interface, now: MonotonicClock.now)
                else { return }
                self.show(event)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.ivan.chelka.network"))
    }

    /// Имя типа подключения. Именно тип, а не SSID: имя сети Wi-Fi
    /// с недавних версий macOS отдаётся только с разрешением на геопозицию,
    /// а просить его ради подписи в вырезе — несоразмерно.
    private nonisolated static func name(for path: NWPath) -> String? {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return T("event.network.ethernet", "Кабель") }
        if path.usesInterfaceType(.cellular) { return T("event.network.cellular", "Сотовая") }
        return nil
    }

    // MARK: - Показ

    /// Подставляет событие напрямую — только для офлайн-снимков интерфейса
    /// (`--snapshot`). Плашка рисуется, лишь когда событие есть, а ждать
    /// настоящей разрядки батареи ради проверки внешнего вида нельзя.
    func injectForPreview(_ event: SystemEvent) {
        current = event
    }

    private func show(_ event: SystemEvent) {
        hideWorkItem?.cancel()
        current = event

        let work = DispatchWorkItem { [weak self] in
            self?.current = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)

        Log.app.info("событие: \(event.title, privacy: .public) \(event.detail ?? "", privacy: .public)")
    }
}
