import AppKit
import SwiftUI
import ChelkaCore

/// Окно настроек.
///
/// Приложение живёт в меню-баре и обычных окон не имеет, поэтому окно
/// создаётся по требованию и активирует приложение вручную — иначе оно
/// откроется за чужими окнами и пользователь его не найдёт.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var didBecomeKeyObserver: NSObjectProtocol?

    private let theme: ThemeController
    private let clipboard: ClipboardService
    private let permissions: PermissionsService

    init(theme: ThemeController, clipboard: ClipboardService, permissions: PermissionsService) {
        self.theme = theme
        self.clipboard = clipboard
        self.permissions = permissions
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
    }

    func show() {
        permissions.refresh()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(theme: theme, clipboard: clipboard, permissions: permissions)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = T("settings.title", "Настройки Chelka")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window

        // Разрешения могут поменяться, пока окно просто открыто — пользователь
        // ушёл в Системные настройки, выдал доступ, вернулся не через пункт
        // меню-бара «Настройки…» (который один и обновлял бы список), а,
        // например, через Mission Control или клик по самому окну. Без этого
        // наблюдателя список показывал бы старое состояние, пока окно не
        // закроют и не откроют заново.
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
