import IOKit
import ChelkaCore

/// Читает температуру и обороты вентиляторов через System Management
/// Controller — тот путь, которым Intel-маки всегда отдавали эти данные.
///
/// Это другой механизм, чем `TemperatureReader` (тот — путь Apple Silicon,
/// система событий HID). SMC не документирован Apple, но раскладка ключей
/// и структуры — де-факто стандарт, которым уже полтора десятка лет
/// пользуются все мониторы вроде iStat, Macs Fan Control, smcFanControl:
/// открыть соединение с сервисом «AppleSMC», спросить четырёхбуквенный ключ
/// («TC0P» — температура у процессора, «F0Ac» — обороты первого вентилятора).
///
/// Проверено эмпирически на Apple Silicon (там этого пути нет и быть не
/// может): вызов не падает, а возвращает обычный код ошибки IOKit —
/// то есть при ошибке в структуре или отсутствии ключа получаем «нет
/// данных», а не крэш. Худший исход не хуже того, что было до этого файла.
final class SMCReader {
    private var connection: io_connect_t = 0
    private(set) var isAvailable = false

    init() {
        connect()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func connect() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            Log.metrics.debug("SMC: сервис AppleSMC не найден")
            return
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            Log.metrics.debug("SMC: не удалось открыть соединение, код \(result)")
            connection = 0
            return
        }
        isAvailable = true
    }

    // MARK: - Известные ключи

    /// Температурные ключи, встречавшиеся на Intel-маках разных поколений.
    /// Модель заранее не известна — пробуем все, оставляем что откликнулось.
    static let temperatureKeys = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC0J",
        "TC1C", "TC2C", "TC3C", "TC4C",
        "TG0P", "TG0D",
    ]

    /// `FNum` — сколько вентиляторов у машины. 0 у Air/безвентиляторных моделей.
    static let fanCountKey = "FNum"

    static func fanSpeedKey(_ index: Int) -> String { "F\(index)Ac" }

    // MARK: - Публичное чтение

    func readTemperatures() -> [TemperatureReading] {
        guard isAvailable else { return [] }

        var readings: [TemperatureReading] = []
        for key in Self.temperatureKeys {
            guard let celsius = readFloatValue(key) else { continue }
            readings.append(TemperatureReading(name: key, celsius: celsius))
        }
        return readings
    }

    struct FanReading: Equatable {
        let index: Int
        let rpm: Double
    }

    /// Обороты по каждому вентилятору. Пустой список — либо машина
    /// без вентилятора (Air, часть Mac mini), либо ключи для этой
    /// конкретной модели не входят в известный набор.
    func readFans() -> [FanReading] {
        guard isAvailable else { return [] }
        guard let count = readIntValue(Self.fanCountKey), count > 0, count <= 8 else { return [] }

        var fans: [FanReading] = []
        for index in 0..<count {
            guard let rpm = readFloatValue(Self.fanSpeedKey(index)) else { continue }
            fans.append(FanReading(index: index, rpm: rpm))
        }
        return fans
    }

    // MARK: - Чтение одного ключа

    /// Значение как число с плавающей точкой — годится и для температуры,
    /// и для оборотов, оба закодированы фиксированной точкой.
    /// Сама арифметика разбора — в `SMCValueDecoder`, проверена тестами.
    private func readFloatValue(_ key: String) -> Double? {
        guard let raw = readRawBytes(key) else { return nil }

        switch raw.type {
        case "sp78": return SMCValueDecoder.decodeSP78(raw.bytes)
        case "flt ": return SMCValueDecoder.decodeFloat32(raw.bytes)
        case "fpe2": return SMCValueDecoder.decodeFPE2(raw.bytes)
        case "ui16": return SMCValueDecoder.decodeUInt16(raw.bytes).map(Double.init)
        default: return nil
        }
    }

    private func readIntValue(_ key: String) -> Int? {
        guard let raw = readRawBytes(key) else { return nil }
        switch raw.type {
        case "ui8 ": return SMCValueDecoder.decodeUInt8(raw.bytes)
        case "ui16": return SMCValueDecoder.decodeUInt16(raw.bytes)
        default: return nil
        }
    }

    private struct RawValue {
        let type: String
        let bytes: [UInt8]
    }

    /// Двухфазный протокол SMC: сначала спрашиваем размер и тип значения
    /// (`kSMCReadKeyInfo`), потом само значение (`kSMCReadBytes`) —
    /// без размера из первого шага байты второго не разобрать.
    private func readRawBytes(_ key: String) -> RawValue? {
        guard connection != 0 else { return nil }

        var infoRequest = SMCParamStruct()
        infoRequest.key = Self.fourCC(key)
        infoRequest.data8 = SMCSelector.readKeyInfo

        guard let infoResponse = call(infoRequest), infoResponse.result == 0 else { return nil }

        let dataSize = infoResponse.keyInfo.dataSize
        guard dataSize > 0, dataSize <= 32 else { return nil }

        var readRequest = SMCParamStruct()
        readRequest.key = Self.fourCC(key)
        readRequest.keyInfo.dataSize = dataSize
        readRequest.data8 = SMCSelector.readBytes

        guard let readResponse = call(readRequest), readResponse.result == 0 else { return nil }

        let type = Self.string(fromFourCC: infoResponse.keyInfo.dataType)
        let bytes = readResponse.bytes.asArray(count: Int(dataSize))
        return RawValue(type: type, bytes: bytes)
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        var mutableInput = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size

        let result = withUnsafePointer(to: &mutableInput) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(
                    connection,
                    SMCSelector.handleYPCEvent,
                    inPtr,
                    MemoryLayout<SMCParamStruct>.size,
                    outPtr,
                    &outputSize
                )
            }
        }

        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    private static func fourCC(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in Array(key.utf8.prefix(4)) { result = (result << 8) | UInt32(byte) }
        return result
    }

    private static func string(fromFourCC value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Раскладка SMC-структур

/// Селекторы вызова `IOConnectCallStructMethod` для сервиса AppleSMC.
/// Значения — часть протокола драйвера, не публичный API Apple.
private enum SMCSelector {
    static let handleYPCEvent: UInt32 = 2
    static let readBytes: UInt8 = 5
    static let readKeyInfo: UInt8 = 9
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// `bytes[32]` без родного массива фиксированного размера в Swift —
/// кортеж повторяет раскладку C-массива один в один, без риска,
/// что Swift сам решит переупаковать что-то умнее.
private struct SMCBytes32 {
    var b: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    func asArray(count: Int) -> [UInt8] {
        let all = [
            b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
            b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15,
            b.16, b.17, b.18, b.19, b.20, b.21, b.22, b.23,
            b.24, b.25, b.26, b.27, b.28, b.29, b.30, b.31,
        ]
        return Array(all.prefix(max(0, min(count, 32))))
    }
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes32()
}
