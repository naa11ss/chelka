import Testing

@testable import ChelkaCore

@Suite("Разбор значений SMC")
struct SMCValueDecoderTests {

    // MARK: - sp78 (температура на Intel)

    @Test("sp78: ноль градусов")
    func sp78Zero() {
        #expect(SMCValueDecoder.decodeSP78([0x00, 0x00]) == 0.0)
    }

    @Test("sp78: целое положительное значение")
    func sp78WholePositive() {
        // 0x2D = 45, дробная часть 0 — ровно 45°C.
        #expect(SMCValueDecoder.decodeSP78([0x2D, 0x00]) == 45.0)
    }

    @Test("sp78: дробная часть")
    func sp78Fraction() {
        // Младший байт 0x80 = 128 = половина от 256 — 45.5°C.
        #expect(SMCValueDecoder.decodeSP78([0x2D, 0x80]) == 45.5)
    }

    @Test("sp78: отрицательное значение (ниже нуля)")
    func sp78Negative() {
        // 0xFF00 как знаковое 16-битное = -256, /256 = -1.0.
        #expect(SMCValueDecoder.decodeSP78([0xFF, 0x00]) == -1.0)
    }

    @Test("sp78: реалистичная рабочая температура")
    func sp78Realistic() {
        // 0x32 = 50 — обычная температура простаивающего Intel-CPU.
        #expect(SMCValueDecoder.decodeSP78([0x32, 0x00]) == 50.0)
    }

    @Test("sp78: недостаточно байт — nil, не крэш")
    func sp78TooShort() {
        #expect(SMCValueDecoder.decodeSP78([0x2D]) == nil)
        #expect(SMCValueDecoder.decodeSP78([]) == nil)
    }

    // MARK: - fpe2 (обороты вентилятора)

    @Test("fpe2: ноль оборотов")
    func fpe2Zero() {
        #expect(SMCValueDecoder.decodeFPE2([0x00, 0x00]) == 0.0)
    }

    @Test("fpe2: реалистичные обороты")
    func fpe2Realistic() {
        // 0x0740 = 1856, /4 = 464 об/мин.
        #expect(SMCValueDecoder.decodeFPE2([0x07, 0x40]) == 464.0)
    }

    @Test("fpe2: высокие обороты под нагрузкой")
    func fpe2HighSpeed() {
        // 0x2EE0 = 12000, /4 = 3000 об/мин — разумный максимум для ноутбучного вентилятора.
        #expect(SMCValueDecoder.decodeFPE2([0x2E, 0xE0]) == 3000.0)
    }

    // MARK: - flt (IEEE754 float, big-endian)

    @Test("flt: сорок пять градусов")
    func floatFortyFive() {
        let value = SMCValueDecoder.decodeFloat32([0x42, 0x34, 0x00, 0x00])
        #expect(value != nil)
        #expect(abs(value! - 45.0) < 0.001)
    }

    @Test("flt: сто с половиной")
    func floatHundredPointFive() {
        let value = SMCValueDecoder.decodeFloat32([0x42, 0xC9, 0x00, 0x00])
        #expect(value != nil)
        #expect(abs(value! - 100.5) < 0.001)
    }

    @Test("flt: недостаточно байт — nil")
    func floatTooShort() {
        #expect(SMCValueDecoder.decodeFloat32([0x42, 0x34]) == nil)
    }

    // MARK: - целые

    @Test("ui16: разбор big-endian")
    func uint16BigEndian() {
        #expect(SMCValueDecoder.decodeUInt16([0x00, 0x02]) == 2)
        #expect(SMCValueDecoder.decodeUInt16([0xFF, 0xFF]) == 65535)
    }

    @Test("ui8: один байт")
    func uint8Single() {
        #expect(SMCValueDecoder.decodeUInt8([0x02]) == 2)
        #expect(SMCValueDecoder.decodeUInt8([]) == nil)
    }

    @Test("ui32: четыре байта big-endian")
    func uint32BigEndian() {
        #expect(SMCValueDecoder.decodeUInt32([0x00, 0x00, 0x00, 0x02]) == 2)
        #expect(SMCValueDecoder.decodeUInt32([0x00, 0x00, 0x01, 0x00]) == 256)
    }

    @Test("ui32: недостаточно байт — nil, не крэш")
    func uint32TooShort() {
        #expect(SMCValueDecoder.decodeUInt32([0x00, 0x02]) == nil)
    }
}
