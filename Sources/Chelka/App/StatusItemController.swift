import AppKit
import Combine
import ChelkaCore

/// Иконка в меню-баре: единственная точка управления приложением,
/// пока нет окна настроек. Без неё `.accessory`-приложение невозможно закрыть.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let theme: ThemeController
    private let onToggleNotch: () -> Void
    private let onOpenSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        theme: ThemeController,
        onToggleNotch: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.theme = theme
        self.onToggleNotch = onToggleNotch
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        rebuildMenu()

        theme.$theme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Chelka"
        )
        button.image?.isTemplate = true
        button.toolTip = "Chelka"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: T("menu.toggle", "Показать виджет"),
            action: #selector(toggleNotch),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(
            title: T("menu.settings", "Настройки…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let themeItem = NSMenuItem(
            title: T("menu.theme", "Тема"),
            action: nil,
            keyEquivalent: ""
        )
        let themeMenu = NSMenu()
        for option in AppTheme.allCases {
            let item = NSMenuItem(title: option.localizedTitle, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == theme.theme ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())

        let version = NSMenuItem(title: "Chelka \(AppInfo.versionString)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let quit = NSMenuItem(
            title: T("menu.quit", "Выйти"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleNotch() {
        onToggleNotch()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = AppTheme(rawValue: raw) else { return }
        theme.set(option)
    }
}
