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
    /// Анонимная память — та, которую в отличие от `externalPages`
    /// (файлового кэша) нельзя просто перечитать с диска. Именно она,
    /// а не `activePages`, входит в формулу занятой памяти — см. `usedBytes`.
    public let internalPages: UInt64
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
        internalPages: UInt64,
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
        self.internalPages = internalPages
        self.pageSize = pageSize
        self.totalBytes = totalBytes
    }

    /// Занятая память в том же смысле, в каком её считает «Мониторинг системы»:
    /// анонимная (не файловая) память плюс проводная плюс сжатая.
    ///
    /// Раньше здесь стояло `activePages + externalPages`, что задваивало
    /// файловый кэш: `external_page_count` — это подмножество активных
    /// (и неактивных) страниц, а не отдельный пул сверху них, и добавление
    /// его к `activePages` считало часть кэша дважды. На реальной машине
    /// с большим кэшем (открытые вкладки браузера, смонтированные файлы)
    /// это давало разрыв c «Мониторингом системы» в десятки процентных
    /// пунктов — 93% против настоящих ~63%. `internal_page_count` (анонимная
    /// память) не пересекается с файловым кэшем в принципе, поэтому именно
    /// он и должен быть здесь, как в самом macOS.
    ///
    /// Наивное «всего минус свободно» показало бы 90% на любом маке —
    /// macOS честно занимает свободную память под кэш и отдаёт по первому
    /// требованию. Такая цифра пугает и ничего не значит.
    public var usedBytes: UInt64 {
        let appPages = internalPages &- purgeablePages
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

        // Intel (путь SMC): `TC0D` — диод прямо на кристалле, есть не на
        // всех моделях, но точнее всего, когда есть. `TC0P` универсален
        // для 15 лет Intel Mac и это ровно то число, которое показывают
        // iStat Menus/Macs Fan Control/smcFanControl подписью «CPU» —
        // с ним и стоит сверяться на слух «горячо/не горячо».
        //
        // Без этой ветки код проваливался в резерв «максимум из всего»
        // ниже — а максимум на реальном MacBookAir8,2 внутри `--diagnose`
        // почти всегда `TC0E`/`TC0F` (цифровые датчики отдельных ядер,
        // честно горячее под нагрузкой на Coffee Lake и новее), а не
        // `TC0P`: разница на этой машине была 74° против 96° — не шум
        // округления, а другой физический смысл показания.
        for key in ["TC0D", "TC0P"] {
            if let reading = plausible.first(where: { $0.name == key }) {
                return reading.celsius
            }
        }

        // Ни датчиков кристалла, ни привычных Intel-ключей — совсем
        // незнакомая модель. Берём максимум из всего, кроме батареи:
        // занижать температуру опаснее, чем завысить.
        let withoutBattery = plausible.filter { !$0.name.lowercased().contains("battery") }
        let pool = withoutBattery.isEmpty ? plausible : withoutBattery
        return pool.map(\.celsius).max()
    }
}

/// Обороты одного вентилятора, его паспортный диапазон и то, чем сейчас
/// управляется скорость — автоматикой прошивки или ручным процентом.
public struct FanSpeed: Sendable, Equatable, Identifiable {
    public let index: Int
    public let rpm: Double
    /// `nil`, если паспортный диапазон не прочитался (незнакомый тип ключа
    /// на этой модели). Обороты всё равно показываем — регулятора просто
    /// не будет, крутить его не от чего.
    public let minRPM: Double?
    public let maxRPM: Double?
    public let override: FanOverride

    public init(index: Int, rpm: Double, minRPM: Double?, maxRPM: Double?, override: FanOverride = .auto) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.override = override
    }

    public var id: Int { index }

    /// Известен ли паспортный диапазон — от этого зависит, можно ли
    /// вообще показать регулятор для этого вентилятора.
    public var hasKnownRange: Bool { minRPM != nil && maxRPM != nil }

    /// Текущие обороты, выраженные в проценте от паспортного диапазона —
    /// то же число, что показывает регулятор в интерфейсе. 0, если
    /// диапазон не известен: регулятор в этом случае и так не рисуется.
    public var currentPercent: Int {
        guard let minRPM, let maxRPM else { return 0 }
        return FanPercent.percent(forRPM: rpm, minRPM: minRPM, maxRPM: maxRPM)
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
    /// Пусто на моделях без вентилятора — это не «датчик не найден»,
    /// а «здесь и не должно быть».
    public let fans: [FanSpeed]

    public init(
        cpuPercent: Double? = nil,
        memory: MemorySample? = nil,
        temperatureCelsius: Double? = nil,
        thermalPressure: ThermalPressure = .nominal,
        fans: [FanSpeed] = []
    ) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.temperatureCelsius = temperatureCelsius
        self.thermalPressure = thermalPressure
        self.fans = fans
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
        case .nominal: return T("thermal.nominal", "норма")
        case .fair: return T("thermal.fair", "тепло")
        case .serious: return T("thermal.serious", "жарко")
        case .critical: return T("thermal.critical", "перегрев")
        }
    }
}
