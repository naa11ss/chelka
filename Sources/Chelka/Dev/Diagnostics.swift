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
        printBluetoothBattery()
        exit(0)
    }

    /// Что реестр IOKit сообщает о заряде подключённых устройств.
    ///
    /// Публичного API для «сколько осталось в левом наушнике» macOS не даёт:
    /// у `IOPSCopyPowerSourcesInfo` есть только сводная строка, а раздельные
    /// значения лежат в реестре под недокументированными ключами, и набор
    /// этих ключей разнится по моделям и прошивкам. Писать чтение вслепую,
    /// по именам из интернета, — ровно та ошибка, которая на Intel-SMC
    /// стоила целого круга удалённой отладки: сначала смотрим, что реально
    /// отдаёт железо, потом пишем код под увиденное.
    private static func printBluetoothBattery() {
        print("")
        print("Заряд подключённых устройств (реестр IOKit):")

        var found = 0
        for service in registryServices(matching: "AppleDeviceManagementHIDEventService") {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any]
            else { continue }

            // Показываем всё, что похоже на заряд, вместе с именем устройства —
            // не угадывая заранее, какие именно ключи тут окажутся.
            let batteryKeys = dictionary.keys.filter { $0.localizedCaseInsensitiveContains("battery") }.sorted()
            guard !batteryKeys.isEmpty else { continue }

            found += 1
            let name = dictionary["Product"] as? String
                ?? dictionary["BD_ADDR"].map { "\($0)" }
                ?? "без имени"
            print("    \(name)")
            for key in batteryKeys {
                print("        \(key) = \(dictionary[key] ?? "nil")")
            }
        }

        if found == 0 {
            print("    ничего не найдено — подключите наушники и запустите снова")
        }

        // Сводка от публичного API — для сравнения с тем, что выше.
        if let power = SystemEventMonitor.currentPowerState() {
            let source = power.isPlugged ? "от сети" : "от батареи"
            let note = power.hasBattery ? "" : ", встроенной батареи нет"
            print("")
            print("Питание Mac (публичный IOPS): \(power.percent)%, \(source)\(note)")
        }
    }

    /// Перебор служб реестра по имени класса.
    private static func registryServices(matching className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
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

        // Единообразный kIOReturnBadArgument на любом ключе выглядит как
        // «структура не того размера», а не «ключа нет» — печатаем
        // раскладку, которую реально посчитал Swift, чтобы свериться
        // с тем, что ждёт драйвер AppleSMC (80 байт), не гадая.
        print("")
        print("Раскладка SMCParamStruct: \(SMCReader.paramStructLayoutDescription)")

        // Сырой дамп независимо от того, распознан ли тип: если FNum или
        // F0Ac молчат в «нормальном» выводе выше, здесь будет видно —
        // ключ не отвечает вообще, или отвечает, но незнакомым типом.
        print("")
        print("Сырой дамп ключевых полей (для разбора, если вентиляторы не нашлись):")
        let rawKeys = ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Md", "F0Tg", "F1Ac", "F1Mn", "F1Mx", "F1Md", "F1Tg"]
            + SMCReader.temperatureKeys
        for key in rawKeys {
            let dump = smc.dumpKey(key)
            if dump.found {
                let bytesHex = dump.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                let decoded = dump.decodedFloat.map { String(format: ", разобрано как %.1f", $0) } ?? ", тип не распознан текущим кодом"
                print("    \(key): тип=«\(dump.type)» размер=\(dump.size) байты=[\(bytesHex)]\(decoded)")
                continue
            }
            // dumpKey стирает разницу между «драйвер не ответил вообще» и
            // «ответил, но result ненулевой» — здесь она и нужна, чтобы
            // понять, это правда незнакомый ключ или сломан сам протокол.
            if let diag = smc.diagnoseKeyInfo(key) {
                print("    \(key): (нет) kernReturn=\(diag.kernReturn) result=\(diag.result) status=\(diag.status) dataSize=\(diag.dataSize)")
            } else {
                print("    \(key): (нет ключа, соединение недоступно)")
            }
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
        // setFanOverride сводит обе записи к одному Bool — здесь важно увидеть,
        // какая из них конкретно отклонена и с каким result от прошивки.
        if let mdDiag = smc.diagnoseWrite("F\(first.index)Md", bytes: [1]) {
            print("    F\(first.index)Md: kernReturn=\(mdDiag.kernReturn) result=\(mdDiag.result) status=\(mdDiag.status)")
        }
        if let tgDiag = smc.diagnoseWrite("F\(first.index)Tg", bytes: SMCValueDecoder.encodeFloat32(targetRPM)) {
            print("    F\(first.index)Tg: kernReturn=\(tgDiag.kernReturn) result=\(tgDiag.result) status=\(tgDiag.status)")
        }

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
