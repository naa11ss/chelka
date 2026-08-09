import AppKit
import ChelkaCore

/// `Chelka --metrics-demo` — проверка метрик на живой машине.
///
/// Числа с датчиков нельзя проверить юнит-тестом: там проверяется арифметика,
/// а здесь — что источники вообще отвечают и что значения осмысленные.
@MainActor
enum MetricsDemo {

    static func run(service: MetricsService) {
        var failures = 0

        func check(_ label: String, _ condition: Bool, detail: String = "") {
            if !condition { failures += 1 }
            print("\(condition ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        print("проверка метрик")
        print("")

        service.startSampling(interval: 0.5)
        settle(2.0)

        let idle = service.snapshot

        // Память.
        if let memory = idle.memory {
            let usedGB = Double(memory.usedBytes) / 1_073_741_824
            let totalGB = Double(memory.totalBytes) / 1_073_741_824
            check("память читается", memory.totalBytes > 0,
                  detail: String(format: "%.1f из %.0f ГБ (%.0f%%)", usedGB, totalGB, memory.usedPercent))
            check("доля памяти в разумных пределах",
                  memory.usedPercent > 1 && memory.usedPercent < 100,
                  detail: String(format: "%.1f%%", memory.usedPercent))
        } else {
            check("память читается", false, detail: "нет данных")
        }

        // Процессор.
        check("загрузка процессора читается", idle.cpuPercent != nil,
              detail: idle.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "нет данных")
        if let cpu = idle.cpuPercent {
            check("загрузка в пределах 0…100", cpu >= 0 && cpu <= 100, detail: String(format: "%.1f%%", cpu))
        }

        // Загрузка процессора должна отражаться на показаниях.
        //
        // Нагрузку крутим в фоне и продолжаем вращать цикл событий: если
        // заблокировать главный поток, таймер замеров не тикнет ни разу
        // и мерить будет нечего.
        let baseline = idle.cpuPercent ?? 0
        startBurn(seconds: 2.5)

        var peak = baseline
        for _ in 0..<8 {
            settle(0.35)
            peak = max(peak, service.snapshot.cpuPercent ?? 0)
        }
        settle(1.0)

        check("нагрузка отражается на показаниях", peak > baseline + 5,
              detail: String(format: "в покое %.1f%%, под нагрузкой %.1f%%", baseline, peak))

        // Температура.
        if let celsius = service.snapshot.temperatureCelsius {
            check("температура читается", (20...110).contains(celsius),
                  detail: String(format: "%.1f °C", celsius))
        } else {
            check("температура читается", false,
                  detail: "приватный API не отдал значений, запасной уровень: \(service.snapshot.thermalPressure.localizedTitle)")
        }

        // Опрос обязан останавливаться.
        service.stopSampling()
        check("опрос останавливается", !service.isSampling)

        print("")
        print(failures == 0 ? "проверка пройдена" : "провалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Фоновая нагрузка в несколько потоков: одного мало, чтобы сдвинуть
    /// общую загрузку восьмиядерной машины на заметную величину.
    /// Не ждём завершения — главный поток должен продолжать крутить замеры.
    private static func startBurn(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)

        for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount - 1) {
            DispatchQueue.global(qos: .userInitiated).async {
                var accumulator: Double = 0
                while Date() < deadline {
                    for value in 0..<200_000 {
                        accumulator += Double(value).squareRoot()
                    }
                }
                // Результат нужен, иначе оптимизатор выбросит цикл целиком.
                if accumulator.isNaN { print("") }
            }
        }
    }
}
