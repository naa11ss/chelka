import Foundation

/// Счётчики тиков процессора. Абсолютные значения бесполезны —
/// смысл имеет только разница между двумя замерами.
public struct CPUTicks: Sendable, Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var total: UInt64 { user &+ system &+ idle &+ nice }
    public var busy: UInt64 { user &+ system &+ nice }
}

public enum CPUUsage {
    /// Доля занятого времени между двумя замерами, 0…100.
    ///
    /// Возвращает `nil`, когда разницы нет: первый замер сравнивать не с чем,
    /// а показывать в этот момент ноль — врать.
    public static func percentage(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        let totalDelta = current.total &- previous.total
        guard totalDelta > 0 else { return nil }

        let busyDelta = current.busy &- previous.busy
        // Счётчики монотонны, но при переполнении или пересчёте ядер
        // разница может оказаться бессмысленной.
        guard busyDelta <= totalDelta else { return nil }

        return Double(busyDelta) / Double(totalDelta) * 100
    }
}

/// Снимок памяти в страницах, как его отдаёт ядро.
public struct MemorySample: Sendable, Equatable {
    public let activePages: UInt64
    public let wiredPages: UInt64
    public let compressedPages: UInt64
    public let inactivePages: UInt64
    public let freePages: UInt64
    public let speculativePages: UInt64
    public let purgeablePages: UInt64
    public let externalPages: UInt64
    public let pageSize: UInt64
    public let totalBytes: UInt64

    public init(
        activePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        inactivePages: UInt64,
        freePages: UInt64,
        speculativePages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64
    ) {
        self.activePages = activePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
        self.inactivePages = inactivePages
        self.freePages = freePages
        self.speculativePages = speculativePages
        self.purgeablePages = purgeablePages
        self.externalPages = externalPages
        self.pageSize = pageSize
        self.totalBytes = totalBytes
    }

    /// Занятая память в том же смысле, в каком её считает «Мониторинг системы»:
    /// активная и проводная память плюс сжатая, без файлового кэша.
    ///
    /// Наивное «всего минус свободно» показало бы 90% на любом маке —
    /// macOS честно занимает свободную память под кэш и отдаёт по первому
    /// требованию. Такая цифра пугает и ничего не значит.
    public var usedBytes: UInt64 {
        let appPages = activePages &+ externalPages &- purgeablePages
        let pages = appPages &+ wiredPages &+ compressedPages
        return pages &* pageSize
    }

    /// Доля занятой памяти, 0…100.
    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }
}

/// Одно показание термодатчика.
public struct TemperatureReading: Sendable, Equatable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public enum SystemTemperature {
    /// Правдоподобный диапазон. Часть датчиков стабильно отдаёт мусор
    /// вроде −1.9 °C — их нельзя усреднять с остальными.
    public static let plausibleRange: ClosedRange<Double> = 5...120

    /// Температура кристалла: среднее по датчикам `tdie`.
    ///
    /// На Apple Silicon десятки датчиков с разными именами. `tdie` — это
    /// сам кристалл, и именно он интересен пользователю; `tdev` меряют
    /// отдельные узлы, `gas gauge battery` — батарею, и в общее среднее
    /// они вносят только шум.
    public static func representative(from readings: [TemperatureReading]) -> Double? {
        let plausible = readings.filter { plausibleRange.contains($0.celsius) }
        guard !plausible.isEmpty else { return nil }

        let die = plausible.filter { $0.name.lowercased().contains("tdie") }
        if !die.isEmpty {
            return die.reduce(0) { $0 + $1.celsius } / Double(die.count)
        }

        // Датчиков кристалла нет (другое поколение железа) — берём максимум
        // из всего, кроме батареи: занижать температуру опаснее, чем завысить.
        let withoutBattery = plausible.filter { !$0.name.lowercased().contains("battery") }
        let pool = withoutBattery.isEmpty ? plausible : withoutBattery
        return pool.map(\.celsius).max()
    }
}

/// Все метрики разом — то, что показывает виджет.
public struct SystemMetricsSnapshot: Sendable, Equatable {
    public let cpuPercent: Double?
    public let memory: MemorySample?
    public let temperatureCelsius: Double?
    /// Уровень теплового давления — публичный запасной вариант,
    /// когда градусы недоступны.
    public let thermalPressure: ThermalPressure

    public init(
        cpuPercent: Double? = nil,
        memory: MemorySample? = nil,
        temperatureCelsius: Double? = nil,
        thermalPressure: ThermalPressure = .nominal
    ) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.temperatureCelsius = temperatureCelsius
        self.thermalPressure = thermalPressure
    }

    public static let empty = SystemMetricsSnapshot()
}

public enum ThermalPressure: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    public var localizedTitle: String {
        switch self {
        case .nominal: return "норма"
        case .fair: return "тепло"
        case .serious: return "жарко"
        case .critical: return "перегрев"
        }
    }
}
