import Foundation

/// Заряд подключённого устройства — по каждому наушнику отдельно,
/// если устройство сообщает раздельно.
public struct DeviceBattery: Sendable, Equatable, Identifiable {
    public let name: String
    /// Наушники сообщают три значения; мышь или клавиатура — одно в `single`.
    public let left: Int?
    public let right: Int?
    public let caseLevel: Int?
    public let single: Int?

    public var id: String { name }

    public init(name: String, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, single: Int? = nil) {
        self.name = name
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.single = single
    }

    /// Есть ли хоть что-то, что стоит показать.
    public var hasAnyLevel: Bool {
        left != nil || right != nil || caseLevel != nil || single != nil
    }

    /// Раздельные значения по наушникам — то, ради чего это всё.
    public var isEarbuds: Bool { left != nil || right != nil }

    /// Самый низкий известный уровень — по нему решается, тревожиться ли.
    public var lowest: Int? {
        [left, right, caseLevel, single].compactMap { $0 }.min()
    }
}

/// Разбирает вывод `system_profiler SPBluetoothDataType -json`.
///
/// Почему именно `system_profiler`, а не реестр IOKit: раздельного заряда
/// наушников в реестре на macOS 26 попросту нет — общеизвестные ключи
/// `BatteryPercentLeft`/`Right`/`Case` там больше не встречаются (проверено
/// на живой машине с подключёнными AirPods: ни одного такого ключа во всём
/// реестре). `system_profiler` — документированная утилита, а не приватный
/// интерфейс, и данные отдаёт полностью.
public enum DeviceBatteryParser {

    /// Ключи, которыми `system_profiler` называет уровни заряда.
    private static let leftKey = "device_batteryLevelLeft"
    private static let rightKey = "device_batteryLevelRight"
    private static let caseKey = "device_batteryLevelCase"
    /// У устройств с одной батареей (мышь, клавиатура) ключ другой.
    private static let singleKeys = ["device_batteryLevelMain", "device_batteryLevel"]

    public static func parse(_ data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var byName: [String: DeviceBattery] = [:]

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }

            for entry in connected {
                for (name, value) in entry {
                    guard let fields = value as? [String: Any] else { continue }
                    let battery = DeviceBattery(
                        name: name,
                        left: percent(fields[leftKey]),
                        right: percent(fields[rightKey]),
                        caseLevel: percent(fields[caseKey]),
                        single: singleKeys.lazy.compactMap { percent(fields[$0]) }.first
                    )
                    guard battery.hasAnyLevel else { continue }

                    // Одно и то же устройство встречается дважды — классическим
                    // подключением и BLE, — и полные данные лежат только в одной
                    // из записей. Берём ту, где их больше, а не ту, что попалась
                    // первой: иначе у наушников остался бы один заряд кейса.
                    if let existing = byName[name], levelCount(existing) >= levelCount(battery) { continue }
                    byName[name] = battery
                }
            }
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    private static func levelCount(_ battery: DeviceBattery) -> Int {
        [battery.left, battery.right, battery.caseLevel, battery.single].compactMap { $0 }.count
    }

    /// Значения приходят строкой вида `"51 %"`.
    private static func percent(_ raw: Any?) -> Int? {
        guard let text = raw as? String else { return raw as? Int }
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
