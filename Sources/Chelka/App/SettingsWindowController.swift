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

    private let theme: ThemeController
    private let clipboard: ClipboardService
    private let permissions: PermissionsService

    init(theme: ThemeController, clipboard: ClipboardService, permissions: PermissionsService) {
        self.theme = theme
        self.clipboard = clipboard
        self.permissions = permissions
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

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
