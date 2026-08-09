import Testing

@testable import ChelkaCore

@Suite("Проценты вентилятора")
struct FanPercentTests {

    @Test("Ноль процентов — минимальные обороты этого вентилятора")
    func zeroPercentIsMinimum() {
        #expect(FanPercent.rpm(forPercent: 0, minRPM: 1200, maxRPM: 6000) == 1200)
    }

    @Test("Сто процентов — паспортный максимум, не выше")
    func hundredPercentIsMaximum() {
        #expect(FanPercent.rpm(forPercent: 100, minRPM: 1200, maxRPM: 6000) == 6000)
    }

    @Test("Половина — середина диапазона")
    func fiftyPercentIsMidpoint() {
        #expect(FanPercent.rpm(forPercent: 50, minRPM: 1000, maxRPM: 5000) == 3000)
    }

    @Test("Обратный пересчёт из оборотов в проценты")
    func rpmBackToPercent() {
        #expect(FanPercent.percent(forRPM: 3000, minRPM: 1000, maxRPM: 5000) == 50)
        #expect(FanPercent.percent(forRPM: 1000, minRPM: 1000, maxRPM: 5000) == 0)
        #expect(FanPercent.percent(forRPM: 5000, minRPM: 1000, maxRPM: 5000) == 100)
    }

    @Test("Округление к шагу пять")
    func snapsToStepOfFive() {
        #expect(FanPercent.snap(17) == 15)
        #expect(FanPercent.snap(18) == 15)
        #expect(FanPercent.snap(22) == 20)
        #expect(FanPercent.snap(23) == 20)
    }

    @Test("Значения за пределами диапазона обрезаются, не выламываются")
    func clampsOutOfRange() {
        #expect(FanPercent.snap(-10) == 0)
        #expect(FanPercent.snap(150) == 100)
        #expect(FanPercent.rpm(forPercent: -20, minRPM: 1000, maxRPM: 5000) == 1000)
        #expect(FanPercent.rpm(forPercent: 999, minRPM: 1000, maxRPM: 5000) == 5000)
    }

    @Test("Вырожденный диапазон (min равен max) не делит на ноль")
    func degenerateRangeIsSafe() {
        #expect(FanPercent.rpm(forPercent: 50, minRPM: 3000, maxRPM: 3000) == 3000)
        #expect(FanPercent.percent(forRPM: 3000, minRPM: 3000, maxRPM: 3000) == 0)
    }

    @Test("Круговой пересчёт процент → RPM → процент не теряет значение на границах шага")
    func roundTripAtStepBoundaries() {
        for percent in stride(from: 0, through: 100, by: 5) {
            let rpm = FanPercent.rpm(forPercent: percent, minRPM: 1500, maxRPM: 6200)
            let back = FanPercent.percent(forRPM: rpm, minRPM: 1500, maxRPM: 6200)
            #expect(back == percent, "percent=\(percent) rpm=\(rpm) back=\(back)")
        }
    }
}

@Suite("Кодирование значений SMC для записи")
struct SMCValueEncoderTests {

    @Test("fpe2: кодирование и разбор дают исходное число")
    func fpe2RoundTrip() {
        for rpm in [0.0, 464.0, 1850.0, 3000.0, 6200.0] {
            let bytes = SMCValueDecoder.encodeFPE2(rpm)
            let decoded = SMCValueDecoder.decodeFPE2(bytes)
            #expect(decoded == rpm, "rpm=\(rpm) bytes=\(bytes) decoded=\(String(describing: decoded))")
        }
    }

    @Test("fpe2: отрицательное значение обрезается в ноль, не переполняет")
    func fpe2ClampsNegative() {
        let bytes = SMCValueDecoder.encodeFPE2(-500)
        #expect(SMCValueDecoder.decodeFPE2(bytes) == 0)
    }

    @Test("fpe2: аномально большое значение обрезается, не переполняет 16 бит")
    func fpe2ClampsHuge() {
        let bytes = SMCValueDecoder.encodeFPE2(999_999)
        let decoded = SMCValueDecoder.decodeFPE2(bytes)
        #expect(decoded != nil)
        #expect(decoded! < 20000)
    }

    @Test("ui8: значение в байт")
    func uint8Encode() {
        #expect(SMCValueDecoder.encodeUInt8(1) == [0x01])
        #expect(SMCValueDecoder.encodeUInt8(0) == [0x00])
    }
}
