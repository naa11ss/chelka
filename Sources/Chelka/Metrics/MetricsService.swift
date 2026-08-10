import AppKit
import Combine
import Darwin
import SwiftUI
@preconcurrency import UserNotifications
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

    /// Паспортные пределы вентиляторов не меняются во время работы —
    /// читаем один раз, а не каждый тик.
    private var fanLimits: [Int: (min: Double, max: Double)] = [:]
    /// Что сейчас реально запрошено у каждого вентилятора: автоматика
    /// или ручной процент. Живёт до explicit смены пользователем или
    /// до выхода из приложения — сворачивание виджета его не сбрасывает.
    private var fanOverrides: [Int: FanOverride] = [:]
    /// Порядковый номер последней заявки на каждый вентилятор — сравнение
    /// `fanOverrides[index] == requested` по значению путало бы старый
    /// ответ с новым, если пользователь дважды подряд выставил один и тот
    /// же процент (например, поправил слайдер туда-обратно): оба запроса
    /// имели бы одинаковое значение, и устаревший ответ мог бы "выиграть"
    /// гонку и затереть только что подтверждённый новый. Здесь сравнивается
    /// сама заявка по номеру, а не то, что она просит.
    private var fanRequestGeneration: [Int: Int] = [:]

    /// Разрешён 0% на регуляторе — страховку от «выключил и забыл» несёт
    /// не сам регулятор, а этот сервис: предупреждает уведомлением, когда
    /// температура растёт при активном ручном режиме, но не отбирает
    /// у пользователя выбор молча — решение вернуть автоматику остаётся за ним.
    private static let overheatThreshold: Double = 90
    /// Гистерезис против дребезга: без него уведомление могло бы уйти
    /// заново на каждом тике, пока температура колеблется около порога.
    private static let overheatResetMargin: Double = 5
    private var hasWarnedOverheat = false

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

        if tickCounter % Self.temperatureEveryNTicks == 0 {
            lastTemperature = SystemTemperature.representative(from: readTemperatures())
        }
        tickCounter += 1

        // Обороты читаются каждый тик, не через раз, как температура:
        // это ровно то число, за которым следит регулятор, пока пользователь
        // его крутит, и задержка отклика там, где ждут живой обратной связи,
        // была бы заметна.
        let fans = readFans()

        // Плавный переход между показаниями вместо мгновенной подмены —
        // числа и полоски в карточке едут к новому значению, а не дёргаются.
        withAnimation(.easeOut(duration: 0.4)) {
            snapshot = SystemMetricsSnapshot(
                cpuPercent: cpuPercent ?? snapshot.cpuPercent,
                memory: readMemory(),
                temperatureCelsius: lastTemperature,
                thermalPressure: currentThermalPressure(),
                fans: fans
            )
        }

        checkOverheatSafety(temperature: lastTemperature, fans: fans)
    }

    // MARK: - Страховка от перегрева

    /// Регулятор разрешает 0% — если температура при этом растёт, дело
    /// пользователя решать, вернуть ли автоматику, но узнать об этом он
    /// должен сразу, а не когда почувствует запах или машина сама уйдёт
    /// в тепловую защиту.
    private func checkOverheatSafety(temperature: Double?, fans: [FanSpeed]) {
        guard let temperature else { return }
        let hasManualOverride = fans.contains {
            if case .percent = $0.override { return true }
            return false
        }

        guard hasManualOverride else {
            hasWarnedOverheat = false
            return
        }

        if temperature >= Self.overheatThreshold {
            guard !hasWarnedOverheat else { return }
            hasWarnedOverheat = true
            postOverheatNotification(temperature: temperature)
        } else if temperature < Self.overheatThreshold - Self.overheatResetMargin {
            hasWarnedOverheat = false
        }
    }

    private func postOverheatNotification(temperature: Double) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = T("fan.overheat.title", "Температура повышена")
        content.body = String(
            format: T("fan.overheat.body", "%.0f °C при вентиляторе в ручном режиме. Проверьте регулятор — возможно, стоит вернуть автоматику."),
            temperature
        )
        content.sound = .default
        let request = UNNotificationRequest(identifier: "chelka.fan.overheat", content: content, trigger: nil)

        // Разрешение может быть ещё не запрошено — просим его здесь же,
        // а не заранее при каждом запуске: до первого ручного управления
        // вентилятором оно попросту не нужно.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
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
            internalPages: UInt64(stats.internal_page_count),
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
    /// карточка в интерфейсе просто не рисует блок оборотов и регулятор.
    /// Вентилятор без известного диапазона всё равно попадает в список —
    /// просто без регулятора, только с показаниями оборотов.
    private func readFans() -> [FanSpeed] {
        smcReader.readFans().map { reading in
            // Паспортный диапазон фиксирован железом — кэшируем при первом
            // успешном чтении вместо того, чтобы спрашивать SMC заново
            // на каждом тике ради чисел, которые не могут измениться.
            // Если в этот раз диапазон не прочитался, но раньше читался —
            // не затираем кэш пустотой из-за случайного сбоя одного опроса.
            if let minRPM = reading.minRPM, let maxRPM = reading.maxRPM {
                fanLimits[reading.index] = (minRPM, maxRPM)
            }
            let limits = fanLimits[reading.index]

            return FanSpeed(
                index: reading.index,
                rpm: reading.rpm,
                minRPM: limits?.min,
                maxRPM: limits?.max,
                override: fanOverrides[reading.index] ?? .auto
            )
        }
    }

    // MARK: - Управление вентилятором

    /// Регулятор: `percent == nil` возвращает вентилятор автоматике
    /// прошивки, иначе задаёт долю от паспортного диапазона оборотов.
    ///
    /// Обороты никогда не просят больше собственного максимума
    /// вентилятора — `FanPercent.rpm` считает от `F{i}Mn…F{i}Mx`,
    /// которые сообщает сам вентилятор, программно перепрыгнуть через
    /// них нельзя даже в принципе: контроллер вентилятора сам обрежет
    /// по своему пределу, что бы мы ни отправили.
    ///
    /// Сама запись — привилегированная (см. `PrivilegedFanWriter`) и может
    /// растянуться на секунды, пока система ждёт пароль администратора,
    /// поэтому ждать её на MainActor синхронно нельзя. UI обновляется
    /// оптимистично сразу, а после завершения записи — по факту: если
    /// пользователь успел подвинуть регулятор ещё раз, пока мы ждали
    /// пароль, более старый ответ уже не должен затирать более новый.
    func setFanOverride(index: Int, percent: Int?) {
        guard let limits = fanLimits[index] else {
            Log.metrics.error("нет паспортного диапазона для вентилятора \(index) — регулятор ещё не читал его")
            return
        }

        let requested: FanOverride = percent.map { .percent(FanPercent.snap($0)) } ?? .auto
        let targetRPM: Double? = percent.map { FanPercent.rpm(forPercent: FanPercent.snap($0), minRPM: limits.min, maxRPM: limits.max) }
        fanOverrides[index] = requested
        let generation = (fanRequestGeneration[index] ?? 0) + 1
        fanRequestGeneration[index] = generation
        // `snapshot` иначе обновился бы только на следующем тике таймера
        // (раз в 1.5 с) — до этого регулятор на мгновение показывал бы
        // старое значение поверх уже отпущенного пальца: выглядит как
        // «прыгнул назад к прошлому проценту, потом сам доехал до нужного».
        patchFanOverride(index: index, override: requested)

        Task { await self.applyPrivilegedWrite(index: index, requested: requested, targetRPM: targetRPM, generation: generation) }
    }

    private func applyPrivilegedWrite(index: Int, requested: FanOverride, targetRPM: Double?, generation: Int) async {
        let success = await PrivilegedFanWriter.write(index: index, targetRPM: targetRPM)
        // Сверяем номер заявки, не значение: более новая заявка (даже с тем
        // же процентом) уже могла обновить `fanOverrides` и `fanRequestGeneration`
        // к моменту, когда этот, более старый, ответ пришёл — тогда он не
        // должен ничего трогать, что бы он ни принёс.
        guard fanRequestGeneration[index] == generation else { return }
        if !success {
            fanOverrides[index] = .auto
            patchFanOverride(index: index, override: .auto)
        }

        // Logger.info(_:) размечает интерполяцию сам (privacy-редактирование
        // в системном логе) и не знает, как описать произвольный enum —
        // без явного String тут была невнятная ошибка компиляции совсем в
        // другом месте (на самом Task{}), а не на этой строке.
        let requestedDescription = switch requested {
        case .auto: "авто"
        case .percent(let value): "\(value)%"
        }
        Log.metrics.info("вентилятор \(index): запрошено \(requestedDescription), \(success ? "принято" : "отклонено")")
    }

    /// Точечно правит override одного вентилятора в уже опубликованном
    /// снапшоте — не дожидаясь следующего тика `sample()`, см. комментарий
    /// в `setFanOverride`.
    private func patchFanOverride(index: Int, override: FanOverride) {
        guard let fanIndex = snapshot.fans.firstIndex(where: { $0.index == index }) else { return }
        var fans = snapshot.fans
        let old = fans[fanIndex]
        fans[fanIndex] = FanSpeed(index: old.index, rpm: old.rpm, minRPM: old.minRPM, maxRPM: old.maxRPM, override: override)

        withAnimation(.easeOut(duration: 0.3)) {
            snapshot = SystemMetricsSnapshot(
                cpuPercent: snapshot.cpuPercent,
                memory: snapshot.memory,
                temperatureCelsius: snapshot.temperatureCelsius,
                thermalPressure: snapshot.thermalPressure,
                fans: fans
            )
        }
    }

    /// Отдаёт все вентиляторы обратно прошивке. Вызывается при выходе
    /// из приложения — ручной режим не должен пережить сам процесс,
    /// который его выставил: иначе обороты застынут там, где их
    /// оставили, даже когда машина остынет.
    ///
    /// Запись привилегированная и асинхронная (см. `setFanOverride`), но
    /// здесь дожидаемся её синхронно — `AppDelegate` вызывает
    /// `PrivilegedFanWriter.shutdown()` сразу следующей строкой, а тот
    /// останавливает демон немедленно. Без ожидания эти заявки на возврат
    /// автоматики почти всегда проигрывали бы гонку с остановкой демона:
    /// `Task { }`, унаследовавший MainActor, не успел бы даже встать
    /// в очередь `FanDaemonSession` до того, как её обнулит teardown,
    /// и следующая попытка писать нашла бы демон не запущенным — пришлось
    /// бы поднимать новый под свежий пароль администратора уже во время
    /// выхода из приложения, что практически никогда не успевает.
    /// `Task.detached` — по той же причине, что и в `ClipboardService.flushSync`:
    /// обычная `Task` унаследовала бы MainActor и не смогла бы выполниться,
    /// пока этот же метод синхронно блокирует его семафором.
    func revertAllFanOverrides() {
        let indices = fanOverrides.compactMap { $0.value != .auto ? $0.key : nil }
        fanOverrides.removeAll()
        guard !indices.isEmpty else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for index in indices {
                    group.addTask { _ = await PrivilegedFanWriter.write(index: index, targetRPM: nil) }
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
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
