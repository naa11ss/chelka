import AppKit
import Combine
import ChelkaCore

/// Заряд подключённых устройств — по каждому наушнику отдельно.
///
/// Источник — `system_profiler SPBluetoothDataType -json`, документированная
/// утилита. Реестр IOKit тут не годится: на macOS 26 раздельного заряда
/// наушников в нём нет вовсе, общеизвестные ключи `BatteryPercentLeft`
/// и соседние там больше не встречаются (проверено на живой машине
/// с подключёнными AirPods — ни одного такого ключа во всём реестре).
///
/// Расплата — цена запуска процесса: `system_profiler` отвечает за секунду
/// с лишним. Поэтому опрос редкий и только пока виджет раскрыт: заряд
/// наушников меняется медленно, и чаще раза в минуту он никому не нужен.
@MainActor
final class DeviceBatteryReader: ObservableObject {

    @Published private(set) var devices: [DeviceBattery] = []

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.ivan.chelka.device-battery", qos: .utility)
    private var isReading = false

    private static let interval: TimeInterval = 60

    var isPolling: Bool { timer != nil }

    func startPolling() {
        guard timer == nil else { return }
        read()

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: - Чтение

    private func read() {
        // Запуск процесса дороже самого опроса — накладывать один на другой
        // тем более незачем.
        guard !isReading else { return }
        isReading = true

        queue.async { [weak self] in
            let data = Self.runSystemProfiler()
            let parsed = data.map(DeviceBatteryParser.parse) ?? []

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isReading = false
                    guard self.devices != parsed else { return }
                    self.devices = parsed
                }
            }
        }
    }

    /// Подставляет устройства напрямую — только для офлайн-снимков
    /// интерфейса (`--snapshot`): вид карточки не должен зависеть от того,
    /// какие наушники подключены к машине, на которой снимки рендерят.
    func injectForPreview(_ devices: [DeviceBattery]) {
        self.devices = devices
    }

    /// Синхронное чтение — для `--diagnose`, где нет ни цикла событий,
    /// ни смысла ждать таймера.
    nonisolated static func readNow() -> [DeviceBattery] {
        guard let data = runSystemProfiler() else { return [] }
        return DeviceBatteryParser.parse(data)
    }

    /// Тот же принцип, что у `AppleScriptBridge`: внешний процесс с жёстким
    /// пределом по времени. Зависший `system_profiler` (а он ходит в железо
    /// и умеет задумываться) не должен утащить за собой виджет.
    private nonisolated static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.metrics.debug("system_profiler не запустился: \(String(describing: error), privacy: .public)")
            return nil
        }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        if process.isRunning {
            process.terminate()
            if group.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 0.3)
            }
            Log.metrics.error("system_profiler не ответил за 8 с — процесс снят")
            return nil
        }

        _ = group.wait(timeout: .now() + 1)
        return data.isEmpty ? nil : data
    }
}
