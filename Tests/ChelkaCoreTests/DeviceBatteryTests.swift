import Foundation
import Testing

@testable import ChelkaCore

/// Слепок реальной структуры `system_profiler SPBluetoothDataType -json`,
/// снятый с живой машины (macOS 26.5.2) с подключёнными наушниками.
/// Имя устройства заменено на нейтральное — репозиторий публичный.
///
/// Устройство здесь дважды не для красоты: система показывает его и
/// классическим подключением, и по BLE, причём раздельный заряд наушников
/// есть только в одной записи, а в другой — один кейс.
private let realSample = """
{
  "SPBluetoothDataType": [
    {
      "device_connected": [
        {
          "AirPods Pro": {
            "device_batteryLevelCase": "51 %",
            "device_batteryLevelLeft": "100 %",
            "device_batteryLevelRight": "95 %",
            "device_address": "40:B3:FA:10:F5:16",
            "device_minorType": "Headphones"
          }
        },
        {
          "AirPods Pro": {
            "device_batteryLevelCase": "51 %",
            "device_address": "D5:4F:1D:8E:4A:F6"
          }
        },
        {
          "Magic Mouse": {
            "device_batteryLevelMain": "72 %"
          }
        }
      ]
    }
  ]
}
"""

@Suite("Заряд подключённых устройств")
struct DeviceBatteryTests {

    private func parseSample() -> [DeviceBattery] {
        DeviceBatteryParser.parse(Data(realSample.utf8))
    }

    @Test("Раздельный заряд наушников разбирается")
    func parsesEarbuds() {
        let airpods = parseSample().first { $0.name == "AirPods Pro" }

        #expect(airpods?.left == 100)
        #expect(airpods?.right == 95)
        #expect(airpods?.caseLevel == 51)
        #expect(airpods?.isEarbuds == true)
    }

    @Test("Из двух записей одного устройства берётся более полная")
    func prefersRicherDuplicate() {
        // Вторая запись того же устройства несёт только заряд кейса —
        // если бы побеждала она, раздельные значения потерялись бы.
        let airpods = parseSample().first { $0.name == "AirPods Pro" }
        #expect(airpods?.left != nil)
        #expect(airpods?.right != nil)
    }

    @Test("Устройство с одной батареей разбирается тоже")
    func parsesSingleBatteryDevice() {
        let mouse = parseSample().first { $0.name == "Magic Mouse" }

        #expect(mouse?.single == 72)
        #expect(mouse?.isEarbuds == false)
    }

    @Test("Проценты вынимаются из строки вида «51 %»")
    func parsesPercentStrings() {
        #expect(parseSample().first { $0.name == "Magic Mouse" }?.single == 72)
    }

    @Test("Самый низкий уровень — по нему решается, тревожиться ли")
    func lowestLevel() {
        #expect(parseSample().first { $0.name == "AirPods Pro" }?.lowest == 51)
    }

    @Test("Мусор вместо JSON не роняет разбор")
    func garbageIsSafe() {
        #expect(DeviceBatteryParser.parse(Data("не json".utf8)).isEmpty)
        #expect(DeviceBatteryParser.parse(Data()).isEmpty)
        #expect(DeviceBatteryParser.parse(Data("{}".utf8)).isEmpty)
    }

    @Test("Устройства без заряда вовсе не попадают в список")
    func skipsDevicesWithoutLevels() {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[{"Клавиатура":{"device_address":"aa"}}]}]}
        """
        #expect(DeviceBatteryParser.parse(Data(json.utf8)).isEmpty)
    }
}
