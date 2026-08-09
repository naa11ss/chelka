import CIOKitShim
import CoreFoundation
import Foundation
import ChelkaCore

/// Показание одного термодатчика.
struct TemperatureSensor: Equatable {
    let name: String
    let celsius: Double
}

/// Читает термодатчики Apple Silicon.
///
/// Публичного API нет: ключи SMC, работавшие на Intel, для M-серии не отдаются,
/// а `ProcessInfo.thermalState` даёт четыре уровня без градусов. Остаётся
/// система событий HID — не документирована, но не требует ни root,
/// ни особых прав, и именно ею пользуются все мониторы под macOS.
///
/// Всё построено так, чтобы исчезновение этого API ничего не сломало:
/// не нашлось клиента, служб или значений — вызывающая сторона просто
/// остаётся без градусов.
final class TemperatureReader {
    private var client: ChelkaIOHIDEventSystemClientRef?
    private var services: [ChelkaIOHIDServiceClientRef] = []
    private(set) var isAvailable = false

    init() {
        connect()
    }

    private func connect() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            Log.metrics.error("система событий HID недоступна — градусов не будет")
            return
        }

        let matching: [String: Any] = [
            "PrimaryUsagePage": CHELKA_SENSOR_USAGE_PAGE,
            "PrimaryUsage": CHELKA_SENSOR_USAGE_TEMPERATURE,
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let servicesArray = IOHIDEventSystemClientCopyServices(client) else {
            Log.metrics.error("термодатчики не перечислены")
            return
        }

        let count = CFArrayGetCount(servicesArray)
        var collected: [ChelkaIOHIDServiceClientRef] = []
        collected.reserveCapacity(count)

        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(servicesArray, index) else { continue }
            collected.append(unsafeBitCast(pointer, to: ChelkaIOHIDServiceClientRef.self))
        }

        self.client = client
        self.services = collected
        self.isAvailable = !collected.isEmpty

        Log.metrics.info("термодатчиков найдено: \(collected.count)")
    }

    /// Снимает показания всех датчиков.
    func readAll() -> [TemperatureSensor] {
        guard isAvailable else { return [] }

        var result: [TemperatureSensor] = []
        result.reserveCapacity(services.count)

        for service in services {
            guard let event = IOHIDServiceClientCopyEvent(
                service,
                Int64(CHELKA_IOHID_EVENT_TYPE_TEMPERATURE),
                0,
                0
            ) else { continue }

            // Функция названа Copy*, но возвращает непрозрачный тип, который
            // Swift не считает CF-объектом и не освобождает сам. Без явного
            // release виджет тёк бы по событию на датчик раз в полторы секунды.
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }

            let value = IOHIDEventGetFloatValue(event, Int32(CHELKA_IOHID_FIELD_TEMPERATURE))
            guard value.isFinite else { continue }

            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? "—"
            result.append(TemperatureSensor(name: name, celsius: value))
        }

        return result
    }
}
