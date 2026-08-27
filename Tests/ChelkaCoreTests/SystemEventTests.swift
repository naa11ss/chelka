import Foundation
import Testing

@testable import ChelkaCore

@Suite("События системы")
struct SystemEventTests {

    private func battery(_ percent: Int, plugged: Bool = false) -> PowerState {
        PowerState(percent: percent, isPlugged: plugged, hasBattery: true)
    }

    @Test("Первое состояние запоминается молча")
    func firstStateIsSilent() {
        var rules = SystemEventRules()
        #expect(rules.onPower(battery(50), now: 100) == nil)
    }

    @Test("Пересечение порога разряда даёт событие")
    func crossingThresholdFires() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(25), now: 100)

        let event = rules.onPower(battery(19), now: 200)
        #expect(event?.kind == .battery)
        #expect(event?.detail == "19%")
    }

    @Test("Ползущий между порогами процент — не новость")
    func driftBetweenThresholdsIsSilent() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(60), now: 100)

        #expect(rules.onPower(battery(55), now: 200) == nil)
        #expect(rules.onPower(battery(40), now: 300) == nil)
        #expect(rules.onPower(battery(21), now: 400) == nil)
    }

    @Test("Один порог не срабатывает дважды")
    func thresholdFiresOnce() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(25), now: 100)

        #expect(rules.onPower(battery(19), now: 200) != nil)
        #expect(rules.onPower(battery(18), now: 300) == nil)
        #expect(rules.onPower(battery(17), now: 400) == nil)
    }

    @Test("Резкое падение сообщает про нижний пройденный порог, не про верхний")
    func steepDropReportsLowestCrossed() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(25), now: 100)

        // 25 → 8 пересекает и 20, и 10: сказать надо про 10, оно тревожнее.
        let event = rules.onPower(battery(8), now: 200)
        #expect(event?.detail == "8%")
        #expect(event?.symbol == "battery.25")
    }

    @Test("Подключение и отключение адаптера — событие")
    func powerConnectionChanges() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(50), now: 100)

        let plugged = rules.onPower(battery(50, plugged: true), now: 200)
        #expect(plugged?.kind == .power)
        #expect(plugged?.symbol == "bolt.fill")

        let unplugged = rules.onPower(battery(50), now: 300)
        #expect(unplugged?.kind == .power)
        #expect(unplugged?.symbol == "battery.50")
    }

    @Test("На зарядке пороги молчат")
    func thresholdsSilentWhileCharging() {
        var rules = SystemEventRules()
        _ = rules.onPower(battery(25, plugged: true), now: 100)
        #expect(rules.onPower(battery(19, plugged: true), now: 200) == nil)
    }

    @Test("Машина без батареи не порождает событий")
    func noBatteryNoEvents() {
        var rules = SystemEventRules()
        let desktop = PowerState(percent: 100, isPlugged: true, hasBattery: false)
        _ = rules.onPower(desktop, now: 100)
        #expect(rules.onPower(desktop, now: 200) == nil)
    }

    @Test("Первый список устройств запоминается молча")
    func firstDeviceListIsSilent() {
        var rules = SystemEventRules()
        let airpods = DeviceBattery(name: "AirPods Pro", left: 90, right: 80, caseLevel: 50)
        #expect(rules.onDevices([airpods], now: 100) == nil)
    }

    @Test("Новое устройство даёт событие с меньшим из наушников")
    func newDeviceReportsLowestEarbud() {
        var rules = SystemEventRules()
        _ = rules.onDevices([], now: 100)

        let airpods = DeviceBattery(name: "AirPods Pro", left: 90, right: 80, caseLevel: 50)
        let event = rules.onDevices([airpods], now: 200)

        #expect(event?.kind == .device)
        #expect(event?.title == "AirPods Pro")
        // Сядет первым правый — про него и говорим.
        #expect(event?.detail == "80%")
        #expect(event?.tint == .positive)
    }

    @Test("Уже известное устройство второй раз не объявляется")
    func knownDeviceStaysSilent() {
        var rules = SystemEventRules()
        let mouse = DeviceBattery(name: "Magic Mouse", single: 70)
        _ = rules.onDevices([], now: 100)
        #expect(rules.onDevices([mouse], now: 200) != nil)
        #expect(rules.onDevices([mouse], now: 300) == nil)
    }

    @Test("Отключение устройства событием не считается")
    func disconnectIsSilent() {
        var rules = SystemEventRules()
        let mouse = DeviceBattery(name: "Magic Mouse", single: 70)
        _ = rules.onDevices([mouse], now: 100)
        #expect(rules.onDevices([], now: 200) == nil)
    }

    @Test("Сеть сообщает только о смене состояния")
    func networkReportsOnlyChanges() {
        var rules = SystemEventRules()
        #expect(rules.onNetwork(isOnline: true, interface: "Wi-Fi", now: 100) == nil)
        #expect(rules.onNetwork(isOnline: true, interface: "Wi-Fi", now: 200) == nil)

        let lost = rules.onNetwork(isOnline: false, interface: nil, now: 300)
        #expect(lost?.kind == .network)
        #expect(lost?.symbol == "wifi.slash")

        let back = rules.onNetwork(isOnline: true, interface: "Wi-Fi", now: 400)
        #expect(back?.detail == "Wi-Fi")
    }
}
