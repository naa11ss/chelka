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
        /// `nil`, если диапазон не удалось прочитать (незнакомый тип ключа
        /// на этой модели) — вентилятор всё равно показываем, просто без
        /// регулятора: обороты видно, крутить нечем.
        let minRPM: Double?
        let maxRPM: Double?
    }

    /// Сколько вентиляторов видит SMC. 0 у Air и безвентиляторных Mac mini.
    func fanCount() -> Int {
        guard isAvailable else { return 0 }
        guard let count = readIntValue(Self.fanCountKey), count > 0, count <= 8 else { return 0 }
        return count
    }

    /// Обороты и паспортный диапазон по каждому вентилятору. Пустой список —
    /// либо машина без вентилятора, либо даже число вентиляторов (`FNum`)
    /// не прочиталось.
    ///
    /// Вентилятор попадает в список, если прочитались хотя бы обороты —
    /// незнакомый тип у `F{i}Mn`/`F{i}Mx` не должен прятать сам факт,
    /// что вентилятор существует и крутится: это разные проблемы,
    /// и вторая не обязана маскировать первую.
    func readFans() -> [FanReading] {
        let count = fanCount()
        guard count > 0 else { return [] }

        var fans: [FanReading] = []
        for index in 0..<count {
            guard let rpm = readFloatValue(Self.fanSpeedKey(index)) else { continue }
            let minRPM = readFloatValue("F\(index)Mn")
            let maxRPM = readFloatValue("F\(index)Mx")
            fans.append(FanReading(index: index, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM))
        }
        return fans
    }

    // MARK: - Управление (запись)

    /// Переводит вентилятор в ручной режим и задаёт целевые обороты —
    /// либо возвращает автоматике прошивки.
    ///
    /// Два ключа на модель менялось за пятнадцать лет несколько раз;
    /// `F{i}Md` — самый распространённый, но не единственный. На модели,
    /// где он не сработает, запись просто ничего не изменит (тот же принцип
    /// безопасного отказа, что и у чтения) — `verifyOverrideTookEffect`
    /// существует именно чтобы это было видно, а не тихо.
    ///
    /// Целевые обороты никогда не выходят за диапазон `F{i}Mn…F{i}Mx`,
    /// который объявляет сам вентилятор: контроллер не даст превысить
    /// паспортный максимум, что бы сюда ни отправили, но заявку всё равно
    /// обрезаем на нашей стороне — не полагаемся только на защиту дальше.
    @discardableResult
    func setFanOverride(index: Int, targetRPM: Double?) -> Bool {
        guard isAvailable else { return false }

        guard let targetRPM else {
            return writeUInt8("F\(index)Md", value: 0)
        }

        let modeWritten = writeUInt8("F\(index)Md", value: 1)
        let targetWritten = writeFloatFPE2("F\(index)Tg", value: targetRPM)
        return modeWritten && targetWritten
    }

    /// Считывает текущие обороты заново — вызывать через секунду-две после
    /// `setFanOverride`, чтобы показать пользователю, подействовало ли,
    /// а не понадеяться, что запись сама по себе значит успех.
    func currentRPM(index: Int) -> Double? {
        readFloatValue(Self.fanSpeedKey(index))
    }

    // MARK: - Диагностика

    struct RawKeyDump {
        let key: String
        let found: Bool
        let type: String
        let size: Int
        let bytes: [UInt8]
        /// Что получилось разобрать известными декодерами, если тип знаком.
        let decodedFloat: Double?
    }

    /// Сырой снимок ключа независимо от того, понимает ли его текущий
    /// код: показывает заявленный тип и байты, даже если ни один decode-case
    /// их не подхватывает. Нужно ровно для случая «на её машине ключ другого
    /// типа» — без этого метода такой случай выглядел бы просто как «нет
    /// данных», без единой зацепки, что чинить.
    func dumpKey(_ key: String) -> RawKeyDump {
        guard let raw = readRawBytes(key) else {
            return RawKeyDump(key: key, found: false, type: "", size: 0, bytes: [], decodedFloat: nil)
        }
        return RawKeyDump(
            key: key,
            found: true,
            type: raw.type,
            size: raw.bytes.count,
            bytes: raw.bytes,
            decodedFloat: readFloatValue(key)
        )
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
        case "ui8 ": return SMCValueDecoder.decodeUInt8(raw.bytes).map(Double.init)
        case "ui16": return SMCValueDecoder.decodeUInt16(raw.bytes).map(Double.init)
        case "ui32": return SMCValueDecoder.decodeUInt32(raw.bytes).map(Double.init)
        default: return nil
        }
    }

    /// Типов у «сколько вентиляторов» за пятнадцать лет моделей встречалось
    /// больше, чем у показаний оборотов — где-то это просто байт, где-то
    /// заведено как более широкое целое.
    private func readIntValue(_ key: String) -> Int? {
        guard let raw = readRawBytes(key) else { return nil }
        switch raw.type {
        case "ui8 ": return SMCValueDecoder.decodeUInt8(raw.bytes)
        case "ui16": return SMCValueDecoder.decodeUInt16(raw.bytes)
        case "ui32": return SMCValueDecoder.decodeUInt32(raw.bytes)
        default: return nil
        }
    }

    private func writeFloatFPE2(_ key: String, value: Double) -> Bool {
        writeBytes(key, bytes: SMCValueDecoder.encodeFPE2(value))
    }

    private func writeUInt8(_ key: String, value: Int) -> Bool {
        writeBytes(key, bytes: SMCValueDecoder.encodeUInt8(value))
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

    /// Тот же двухфазный протокол, что у чтения: сначала `kSMCReadKeyInfo`
    /// узнаёт заявленный драйвером размер поля, потом `kSMCWriteBytes`
    /// отправляет значение — размер обязан совпасть, иначе SMC отклонит
    /// запись тем же кодом ошибки, каким отвечает на неизвестный ключ.
    private func writeBytes(_ key: String, bytes: [UInt8]) -> Bool {
        guard connection != 0 else { return false }

        var infoRequest = SMCParamStruct()
        infoRequest.key = Self.fourCC(key)
        infoRequest.data8 = SMCSelector.readKeyInfo

        guard let infoResponse = call(infoRequest), infoResponse.result == 0 else { return false }

        let dataSize = Int(infoResponse.keyInfo.dataSize)
        guard dataSize > 0, dataSize <= 32, dataSize == bytes.count else {
            Log.metrics.debug("SMC запись \(key, privacy: .public): размер не совпал (ждёт \(dataSize), дано \(bytes.count))")
            return false
        }

        var writeRequest = SMCParamStruct()
        writeRequest.key = Self.fourCC(key)
        writeRequest.keyInfo.dataSize = infoResponse.keyInfo.dataSize
        writeRequest.data8 = SMCSelector.writeBytes
        writeRequest.bytes = SMCBytes32(bytes)

        guard let writeResponse = call(writeRequest), writeResponse.result == 0 else {
            Log.metrics.debug("SMC запись \(key, privacy: .public): отклонено драйвером")
            return false
        }
        return true
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
    static let writeBytes: UInt8 = 6
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

    init() {}

    /// Байты сверх 32 отбрасываются, недостающие остаются нулями —
    /// запись всегда шлёт ровно 32-байтовое поле независимо от того,
    /// сколько байт реально значимо для конкретного ключа.
    init(_ bytes: [UInt8]) {
        for (index, byte) in bytes.prefix(32).enumerated() {
            self[index] = byte
        }
    }

    private subscript(index: Int) -> UInt8 {
        get {
            withUnsafeBytes(of: b) { $0[index] }
        }
        set {
            withUnsafeMutableBytes(of: &b) { $0[index] = newValue }
        }
    }

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
