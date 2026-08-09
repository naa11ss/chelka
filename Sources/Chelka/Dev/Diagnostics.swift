import AppKit
import ChelkaCore

/// `Chelka --diagnose` — печатает, что приложение реально увидело на этой машине:
/// экраны, вырез, посчитанную раскладку. Первый инструмент при разборе
/// «у меня виджет не там» — без него пришлось бы гадать по скриншотам.
@MainActor
enum Diagnostics {

    static func run() -> Never {
        print("Chelka \(AppInfo.versionString)")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")

        let screens = NSScreen.screens
        print("Экранов: \(screens.count)")

        for (index, screen) in screens.enumerated() {
            let metrics = screen.chelkaMetrics
            let layout = NotchGeometry.layout(for: metrics)
            let mark = screen === NSScreen.chelkaTarget ? " ← виджет здесь" : ""

            print("")
            print("[\(index)] \(screen.localizedName)\(mark)")
            print("    frame:        \(short(metrics.frame))")
            print("    safeAreaTop:  \(metrics.safeAreaTop)")
            print("    aux left/right: \(describe(metrics.auxiliaryLeftWidth)) / \(describe(metrics.auxiliaryRightWidth))")
            print("    menuBar:      \(metrics.menuBarHeight)")
            print("    backingScale: \(screen.backingScaleFactor)")
            print("    тип:          \(layout.kind)")
            print("    свёрнутый:    \(short(layout.collapsedRectScreen))")
            print("    раскрытый:    \(short(layout.expandedRectScreen))")
            print("    зона наведения: \(short(layout.hoverRectScreen))")
            print("    панель:       \(short(layout.panelFrame))")
        }

        printSensors()
        exit(0)
    }

    private static func printSensors() {
        print("")
        let hidReader = TemperatureReader()
        let hidSensors = hidReader.readAll().sorted { $0.name < $1.name }

        print("Термодатчики (HID, Apple Silicon): \(hidSensors.count)")
        for sensor in hidSensors {
            print(String(format: "    %-34@ %6.2f °C", sensor.name as NSString, sensor.celsius))
        }

        let smc = SMCReader()
        print("")
        print("SMC сервис доступен: \(smc.isAvailable)")

        let smcTemps = smc.readTemperatures()
        print("Термодатчики (SMC, Intel): \(smcTemps.count)")
        for sensor in smcTemps {
            print(String(format: "    %-6@ %6.2f °C", sensor.name as NSString, sensor.celsius))
        }

        // Сырой дамп независимо от того, распознан ли тип: если FNum или
        // F0Ac молчат в «нормальном» выводе выше, здесь будет видно —
        // ключ не отвечает вообще, или отвечает, но незнакомым типом.
        print("")
        print("Сырой дамп ключевых полей (для разбора, если вентиляторы не нашлись):")
        let rawKeys = ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Md", "F1Ac", "F1Mn", "F1Mx", "F1Md"]
        for key in rawKeys {
            let dump = smc.dumpKey(key)
            if !dump.found {
                print("    \(key): ключ не отвечает")
                continue
            }
            let bytesHex = dump.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let decoded = dump.decodedFloat.map { String(format: ", разобрано как %.1f", $0) } ?? ", тип не распознан текущим кодом"
            print("    \(key): тип=«\(dump.type)» размер=\(dump.size) байты=[\(bytesHex)]\(decoded)")
        }

        let fans = smc.readFans()
        print("")
        print("Вентиляторы: \(fans.isEmpty ? "нет" : "\(fans.count)")")
        for fan in fans {
            let range: String
            if let minRPM = fan.minRPM, let maxRPM = fan.maxRPM {
                range = String(format: "диапазон %.0f…%.0f", minRPM, maxRPM)
            } else {
                range = "диапазон не определён — регулятор недоступен"
            }
            print(String(format: "    вентилятор %d: %.0f об/мин, %@", fan.index, fan.rpm, range))
        }

        guard let first = fans.first, let minRPM = first.minRPM, let maxRPM = first.maxRPM else {
            if !fans.isEmpty {
                print("")
                print("Пробную запись пропускаю: паспортный диапазон первого вентилятора не известен.")
            }
            return
        }

        print("")
        print("Пробная запись на вентиляторе \(first.index): 50% от диапазона…")
        let targetRPM = (minRPM + maxRPM) / 2
        let writeOK = smc.setFanOverride(index: first.index, targetRPM: targetRPM)
        print("    запись: \(writeOK ? "принята" : "отклонена")")

        Thread.sleep(forTimeInterval: 1.5)
        let after = smc.currentRPM(index: first.index)
        print("    обороты через 1.5 с: \(after.map { String(format: "%.0f", $0) } ?? "не читается")")
        print("    ожидалось около: \(String(format: "%.0f", targetRPM))")

        print("")
        print("Возврат к автоматике…")
        let revertOK = smc.setFanOverride(index: first.index, targetRPM: nil)
        print("    запись: \(revertOK ? "принята" : "отклонена")")
    }

    private static func short(_ rect: CGRect) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }

    private static func describe(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "нет"
    }
}
