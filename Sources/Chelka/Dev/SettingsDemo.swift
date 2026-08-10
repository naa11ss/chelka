import AppKit
import ChelkaCore

/// `Chelka --settings-demo` — проверка окна настроек и сохранения выбора.
///
/// Открыть меню-бар и потыкать мышью автоматически нельзя, но убедиться,
/// что окно строится, показывается и что переключатели доходят до диска, —
/// можно.
@MainActor
enum SettingsDemo {

    static func run(
        window: SettingsWindowController,
        theme: ThemeController,
        widgetSize: WidgetSizeController,
        clipboard: ClipboardService,
        permissions: PermissionsService
    ) {
        var failures = 0

        func check(_ label: String, _ condition: Bool, detail: String = "") {
            if !condition { failures += 1 }
            print("\(condition ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        print("проверка настроек")
        print("")

        window.show()
        settle(0.8)

        let settingsWindow = NSApp.windows.first { $0.title.contains("Chelka") || $0.title.contains("Settings") }
        check("окно настроек открылось", settingsWindow?.isVisible == true,
              detail: settingsWindow?.title ?? "окна нет")
        check("размер окна разумный",
              (settingsWindow?.frame.width ?? 0) >= 400 && (settingsWindow?.frame.height ?? 0) >= 300,
              detail: settingsWindow.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "—")

        // Тема сохраняется между запусками.
        let original = theme.theme
        theme.set(.light)
        settle(0.2)
        let stored = UserDefaults.standard.string(forKey: "chelka.theme")
        check("выбор темы уходит в настройки", stored == "light", detail: stored ?? "нет")
        theme.set(original)

        // Размер виджета сохраняется между запусками и остаётся в границах.
        let originalScale = widgetSize.scale
        widgetSize.set(1.15)
        settle(0.2)
        let storedScale = UserDefaults.standard.object(forKey: "chelka.widgetScale") as? Double
        check("размер виджета уходит в настройки", storedScale == 1.15, detail: storedScale.map { "\($0)" } ?? "нет")
        widgetSize.set(5.0)
        check("значение вне диапазона обрезается", widgetSize.scale == WidgetSizeController.range.upperBound,
              detail: "\(widgetSize.scale)")
        widgetSize.set(originalScale)

        // Переключатели буфера.
        let originalScreenshots = clipboard.settings.captureScreenshots
        clipboard.settings.captureScreenshots.toggle()
        settle(0.2)
        check("переключатель снимков сохраняется",
              UserDefaults.standard.bool(forKey: "chelka.clipboard.captureScreenshots") == clipboard.settings.captureScreenshots)
        clipboard.settings.captureScreenshots = originalScreenshots

        // Разрешения перечислены и у каждого есть объяснение.
        permissions.refresh()
        check("разрешения перечислены", permissions.items.count == 5,
              detail: "\(permissions.items.count)")
        check("у каждого разрешения есть объяснение и цена отказа",
              permissions.items.allSatisfy { !$0.explanation.isEmpty && !$0.cost.isEmpty })

        print("")
        for item in permissions.items {
            let mark: String
            switch item.state {
            case .granted: mark = "✓"
            case .denied: mark = "✗"
            case .unknown: mark = "?"
            }
            print("  \(mark) \(item.title)")
        }

        print("")
        print("автозапуск: \(LaunchAtLogin.isEnabled ? "включён" : "выключен")\(LaunchAtLogin.isBlockedBySystem ? " (запрещён системой)" : "")")

        settingsWindow?.close()

        print("")
        print(failures == 0 ? "проверка пройдена" : "провалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
