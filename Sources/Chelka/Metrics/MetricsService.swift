import AppKit
import Combine
import Darwin
import ChelkaCore

/// Снимает загрузку процессора, память и температуру.
///
/// Опрос идёт только пока виджет раскрыт. Постоянный мониторинг в фоне —
/// главная причина, по которой такие виджеты жгут батарею: раз в секунду
/// будить процессор ради цифр, на которые никто не смотрит, незачем.
@MainActor
final class MetricsService: ObservableObject {

    @Published private(set) var snapshot: SystemMetricsSnapshot = .empty

    private var timer: Timer?
    private var previousTicks: CPUTicks?
    private let temperatureReader = TemperatureReader()
    private let smcReader = SMCReader()

    /// Температура меняется медленно, а опрос стоит трёх десятков обращений
    /// к системе событий HID — читаем её через раз.
    private var tickCounter = 0
    private static let temperatureEveryNTicks = 3

    private var lastTemperature: Double?

    var isSampling: Bool { timer != nil }

    func startSampling(interval: TimeInterval = 1.5) {
        guard timer == nil else { return }

        sample()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Log.metrics.debug("опрос метрик запущен")
    }

    func stopSampling() {
        timer?.invalidate()
        timer = nil
        // Следующее раскрытие начинает счёт заново: разница со старым
        // замером усреднила бы загрузку за всё время, пока виджет был закрыт.
        previousTicks = nil
        tickCounter = 0

        Log.metrics.debug("опрос метрик остановлен")
    }

    deinit { timer?.invalidate() }

    // MARK: - Замер

    private func sample() {
        let ticks = readCPUTicks()
        var cpuPercent: Double?

        if let ticks {
            if let previous = previousTicks {
                cpuPercent = CPUUsage.percentage(from: previous, to: ticks)
            }
            previousTicks = ticks
        }

        var fans: [FanSpeed] = []
        if tickCounter % Self.temperatureEveryNTicks == 0 {
            lastTemperature = SystemTemperature.representative(from: readTemperatures())
            fans = readFans()
        } else {
            fans = snapshot.fans
        }
        tickCounter += 1

        snapshot = SystemMetricsSnapshot(
            cpuPercent: cpuPercent ?? snapshot.cpuPercent,
            memory: readMemory(),
            temperatureCelsius: lastTemperature,
            thermalPressure: currentThermalPressure(),
            fans: fans
        )
    }

    // MARK: - Источники

    /// Совокупные тики по всем ядрам. `HOST_CPU_LOAD_INFO` даёт их одним
    /// вызовом — перебирать ядра по отдельности ради общей цифры незачем.
    private func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            Log.metrics.error("host_statistics вернул \(result)")
            return nil
        }

        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private func readMemory() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            Log.metrics.error("host_statistics64 вернул \(result)")
            return nil
        }

        return MemorySample(
            activePages: UInt64(stats.active_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            inactivePages: UInt64(stats.inactive_count),
            freePages: UInt64(stats.free_count),
            speculativePages: UInt64(stats.speculative_count),
            purgeablePages: UInt64(stats.purgeable_count),
            externalPages: UInt64(stats.external_page_count),
            pageSize: UInt64(vm_kernel_page_size),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Apple Silicon отвечает через систему событий HID; на Intel этот путь
    /// пуст, и в дело идёт SMC. Приложение не спрашивает архитектуру —
    /// просто пробует оба и берёт то, что реально откликнулось. Так надёжнее:
    /// если Apple завтра поменяет местами доступность путей на каком-то
    /// поколении железа, код не нужно будет чинить отдельно.
    private func readTemperatures() -> [TemperatureReading] {
        let hid = temperatureReader.readAll().map {
            TemperatureReading(name: $0.name, celsius: $0.celsius)
        }
        if !hid.isEmpty { return hid }
        return smcReader.readTemperatures()
    }

    /// Пусто на моделях без вентилятора (Air и часть Mac mini) —
    /// карточка в интерфейсе просто не рисует блок оборотов.
    private func readFans() -> [FanSpeed] {
        smcReader.readFans().map { FanSpeed(index: $0.index, rpm: $0.rpm) }
    }

    /// Публичный запасной показатель: работает всегда, но без градусов.
    private func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
