import Foundation
import Testing

@testable import ChelkaCore

@Suite("Загрузка процессора")
struct CPUUsageTests {

    @Test("Половина тиков занята — пятьдесят процентов")
    func halfBusy() {
        let before = CPUTicks(user: 100, system: 0, idle: 100, nice: 0)
        let after = CPUTicks(user: 200, system: 0, idle: 200, nice: 0)

        #expect(CPUUsage.percentage(from: before, to: after) == 50)
    }

    @Test("Полная загрузка — сто процентов")
    func fullyBusy() {
        let before = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let after = CPUTicks(user: 50, system: 50, idle: 0, nice: 0)

        #expect(CPUUsage.percentage(from: before, to: after) == 100)
    }

    @Test("Без разницы между замерами значения нет")
    func noDeltaMeansNoValue() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 10)
        #expect(CPUUsage.percentage(from: ticks, to: ticks) == nil)
    }

    @Test("Системное время учитывается наравне с пользовательским")
    func systemCountsAsBusy() {
        let before = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let after = CPUTicks(user: 10, system: 30, idle: 60, nice: 0)

        #expect(CPUUsage.percentage(from: before, to: after) == 40)
    }

    @Test("Испорченные счётчики не дают значений больше ста")
    func brokenCountersRejected() {
        let before = CPUTicks(user: 0, system: 0, idle: 100, nice: 0)
        // idle уехал назад — так бывает при пересчёте ядер.
        let after = CPUTicks(user: 100, system: 0, idle: 50, nice: 0)

        let result = CPUUsage.percentage(from: before, to: after)
        #expect(result == nil || result! <= 100)
    }
}

@Suite("Память")
struct MemorySampleTests {

    private func sample(active: UInt64, wired: UInt64, compressed: UInt64, free: UInt64) -> MemorySample {
        MemorySample(
            activePages: active,
            wiredPages: wired,
            compressedPages: compressed,
            inactivePages: free,
            freePages: free,
            speculativePages: 0,
            purgeablePages: 0,
            externalPages: 0,
            internalPages: active,
            pageSize: 16384,
            totalBytes: 16 * 1024 * 1024 * 1024
        )
    }

    @Test("Занятая память складывается из анонимной, проводной и сжатой")
    func usedBytesComposition() {
        let memory = sample(active: 100, wired: 50, compressed: 25, free: 1000)
        #expect(memory.usedBytes == 175 * 16384)
    }

    @Test("Файловый кэш не считается занятой памятью")
    func cacheIsNotCountedAsUsed() {
        // Файловый кэш — это activePages/externalPages, а не internalPages:
        // formula должна игнорировать его, сколько бы там ни было страниц.
        let cached = MemorySample(
            activePages: 900_500,
            wiredPages: 500,
            compressedPages: 0,
            inactivePages: 900_000,
            freePages: 100,
            speculativePages: 500_000,
            purgeablePages: 0,
            externalPages: 900_000,
            internalPages: 1000,
            pageSize: 16384,
            totalBytes: 16 * 1024 * 1024 * 1024
        )
        #expect(cached.usedPercent < 20)
    }

    @Test("Доля не превышает ста процентов")
    func percentIsClamped() {
        let overloaded = MemorySample(
            activePages: 10_000_000,
            wiredPages: 10_000_000,
            compressedPages: 10_000_000,
            inactivePages: 0,
            freePages: 0,
            speculativePages: 0,
            purgeablePages: 0,
            externalPages: 0,
            internalPages: 10_000_000,
            pageSize: 16384,
            totalBytes: 16 * 1024 * 1024 * 1024
        )
        #expect(overloaded.usedPercent == 100)
    }

    @Test("Нулевой объём памяти не приводит к делению на ноль")
    func zeroTotalIsSafe() {
        let broken = MemorySample(
            activePages: 10,
            wiredPages: 10,
            compressedPages: 0,
            inactivePages: 0,
            freePages: 0,
            speculativePages: 0,
            purgeablePages: 0,
            externalPages: 0,
            internalPages: 10,
            pageSize: 16384,
            totalBytes: 0
        )
        #expect(broken.usedPercent == 0)
    }
}

@Suite("Выбор показания температуры")
struct SystemTemperatureTests {

    /// Реальный набор с MacBook Air M2, снятый через `--diagnose`.
    private let realSensors: [TemperatureReading] = [
        .init(name: "PMU tdev1", celsius: 36.2),
        .init(name: "PMU tdev7", celsius: 35.82),
        .init(name: "PMU tdie1", celsius: 48.27),
        .init(name: "PMU tdie2", celsius: 48.27),
        .init(name: "PMU tdie3", celsius: 47.62),
        .init(name: "PMU2 tdie1", celsius: 45.02),
        .init(name: "PMU2 tdev1", celsius: -1.92),
        .init(name: "PMU2 tcal", celsius: 51.85),
        .init(name: "gas gauge battery", celsius: 31.0),
    ]

    @Test("Берутся датчики кристалла, а не всё подряд")
    func prefersDieSensors() {
        let value = SystemTemperature.representative(from: realSensors)
        let expected = (48.27 + 48.27 + 47.62 + 45.02) / 4

        #expect(value != nil)
        #expect(abs(value! - expected) < 0.01)
    }

    @Test("Мусорные показания отбрасываются")
    func discardsImplausibleReadings() {
        let readings: [TemperatureReading] = [
            .init(name: "PMU tdie1", celsius: -1.92),
            .init(name: "PMU tdie2", celsius: 44),
        ]
        #expect(SystemTemperature.representative(from: readings) == 44)
    }

    @Test("На Intel берётся TC0P, а не максимум из цифровых датчиков ядер")
    func prefersTC0POnIntel() {
        // Реальный набор с MacBookAir8,2, снятый через --diagnose под нагрузкой
        // компиляции: TC0E/TC0F честно горячее (цифровые датчики ядер), но
        // TC0P — то число, что 15 лет показывают сторонние утилиты как «CPU»
        // и что ближе всего к ощущению корпуса на ощупь.
        let readings: [TemperatureReading] = [
            .init(name: "TC0P", celsius: 74.31),
            .init(name: "TC0E", celsius: 93.55),
            .init(name: "TC0F", celsius: 96.13),
            .init(name: "TC1C", celsius: 83.0),
            .init(name: "TC2C", celsius: 87.0),
        ]
        #expect(SystemTemperature.representative(from: readings) == 74.31)
    }

    @Test("На Intel без TC0P, но с TC0D — используется диод, а не максимум")
    func prefersTC0DWhenTC0PMissing() {
        let readings: [TemperatureReading] = [
            .init(name: "TC0D", celsius: 71.0),
            .init(name: "TC0F", celsius: 95.0),
        ]
        #expect(SystemTemperature.representative(from: readings) == 71.0)
    }

    @Test("Без датчиков кристалла берётся максимум, кроме батареи")
    func fallsBackToMaximumWithoutBattery() {
        let readings: [TemperatureReading] = [
            .init(name: "gas gauge battery", celsius: 90),
            .init(name: "SOC MTR Temp Sensor1", celsius: 55),
            .init(name: "PMU tdev3", celsius: 42),
        ]
        #expect(SystemTemperature.representative(from: readings) == 55)
    }

    @Test("Пустой список датчиков даёт отсутствие значения, а не ноль")
    func emptyMeansNil() {
        #expect(SystemTemperature.representative(from: []) == nil)
        #expect(SystemTemperature.representative(from: [.init(name: "битый", celsius: -50)]) == nil)
    }
}
