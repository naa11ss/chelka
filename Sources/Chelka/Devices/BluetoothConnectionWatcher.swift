import Foundation
import IOBluetooth
import ChelkaCore

/// Сообщает, что подключилось bluetooth-устройство.
///
/// Нужен ровно затем, чтобы не опрашивать `system_profiler` по таймеру
/// круглые сутки: запуск процесса стоит секунду с лишним, а наушники
/// подключают несколько раз в день. Система будит нас сама, и только тогда
/// имеет смысл сходить за раскладом заряда.
///
/// `IOBluetooth` — старый Objective-C фреймворк, поэтому обёртка на
/// `NSObject` с селектором: ничего современнее для этого уведомления
/// Apple не предлагает.
final class BluetoothConnectionWatcher: NSObject {

    /// Вызывается при подключении любого устройства, на главной очереди.
    var onConnect: (() -> Void)?

    private var registration: IOBluetoothUserNotification?

    func start() {
        guard registration == nil else { return }
        registration = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    func stop() {
        registration?.unregister()
        registration = nil
    }

    deinit { stop() }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Log.metrics.info("bluetooth: устройство подключилось")
        DispatchQueue.main.async { [weak self] in
            self?.onConnect?()
        }
    }
}
