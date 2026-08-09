import AppKit
import ServiceManagement
import ChelkaCore

/// Автозапуск при входе в систему.
///
/// `SMAppService` вместо старого списка объектов входа: пользователь может
/// отключить автозапуск в Системных настройках, и приложение обязано это
/// увидеть, а не спорить со своей галочкой.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Пользователь запретил автозапуск в Системных настройках.
    /// Наша галочка в этом случае ничего не изменит — нужно объяснить, куда идти.
    static var isBlockedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("автозапуск \(enabled ? "включён" : "выключен")")
            return true
        } catch {
            Log.app.error("автозапуск не переключился: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
