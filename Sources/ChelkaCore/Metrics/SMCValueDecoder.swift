import Foundation

/// Разбор значений SMC из сырых байт по объявленному типу.
///
/// Вынесено из `SMCReader` намеренно: сам по себе SMC недоступен без
/// реального Intel-железа и не тестируется юнит-тестами, а вот арифметика
/// разбора байт (порядок байт, знак, масштаб фиксированной точки) —
/// ровно то место, где легко ошибиться на бит или на порядок, и ровно
/// то, что можно и нужно проверить без единого обращения к железу.
public enum SMCValueDecoder {

    /// Классическая кодировка температуры на Intel Mac: 16 бит,
    /// big-endian, старшие 8 бит — знаковое целое, младшие 8 — доли градуса.
    public static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    /// IEEE754 float, 4 байта, little-endian.
    ///
    /// В отличие от `sp78`/`fpe2` — это не самодельная SMC-кодировка с
    /// фиксированной раскладкой бит, а сырое представление C-типа `float`
    /// в памяти. На Intel-Mac (x86_64) это значит little-endian — проверено
    /// на реальном железе (MacBookAir8,2): большие Mn/Mx вентилятора при
    /// big-endian декодировались в денормализованный мусор около нуля,
    /// а Ac/Mn/Mx/Tg разом превращались в круглые осмысленные обороты
    /// (2700/8000 об/мин) только при перемене порядка байт на little-endian.
    public static func decodeFloat32(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        return Double(Float(bitPattern: bits))
    }

    /// Обороты вентилятора: 16 бит без знака, big-endian, младшие 2 бита —
    /// дробная часть (степень двойки — «e2» в имени типа).
    public static func decodeFPE2(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    public static func decodeUInt16(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        return Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    public static func decodeUInt8(_ bytes: [UInt8]) -> Int? {
        bytes.first.map(Int.init)
    }

    public static func decodeUInt32(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Int(value)
    }

    // MARK: - Кодирование (для записи целевых оборотов вентилятора)

    /// Обратная операция к `decodeFPE2` — целевые обороты в байты для записи.
    /// Отрицательные и слишком большие значения обрезаются: писать в
    /// контроллер вентилятора мусор нельзя, даже если вызывающий код ошибся.
    public static func encodeFPE2(_ rpm: Double) -> [UInt8] {
        let clamped = max(0, min(rpm, 16383))
        let raw = UInt16((clamped * 4).rounded())
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    public static func encodeUInt8(_ value: Int) -> [UInt8] {
        [UInt8(clamping: value)]
    }

    /// Обратная операция к `decodeFloat32` — little-endian, как и чтение:
    /// на моделях, где `F{i}Tg` объявлен типом `flt`, а не `fpe2`, писать
    /// нужно этим кодировщиком, иначе `writeBytes` отклонит запись по
    /// несовпадению размера (4 байта против 2 у `encodeFPE2`).
    public static func encodeFloat32(_ rpm: Double) -> [UInt8] {
        let clamped = rpm.isFinite ? max(0, rpm) : 0
        let bits = Float(clamped).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }
}
