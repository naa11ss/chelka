import AppKit
import ChelkaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeController: ThemeController!
    private var clipboardService: ClipboardService!
    private var metricsService: MetricsService!
    private var notchController: NotchController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Chelka запущена, версия \(AppInfo.versionString, privacy: .public)")

        themeController = ThemeController()
        clipboardService = ClipboardService()
        metricsService = MetricsService()
        notchController = NotchController(
            theme: themeController,
            clipboard: clipboardService,
            metrics: metricsService
        )
        statusItemController = StatusItemController(
            theme: themeController,
            onToggleNotch: { [weak self] in self?.notchController.toggleFromMenu() }
        )

        clipboardService.start()
        notchController.start()

        // ⌥⌘V открывает виджет на истории буфера.
        HotkeyCenter.shared.register(HotkeyCenter.defaultBinding) { [weak self] in
            self?.notchController.openPinned()
        }

        if CommandLine.arguments.contains("--metrics-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [metricsService] in
                MetricsDemo.run(service: metricsService!)
            }
        }

        if CommandLine.arguments.contains("--clipboard-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [clipboardService] in
                ClipboardDemo.run(service: clipboardService!)
            }
        }

        if CommandLine.arguments.contains("--hover-demo") {
            // Даём панели встать на место, потом прогоняем сценарий.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [notchController] in
                HoverDemo.run(controller: notchController!)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardService?.stop()
        notchController?.stop()
        Log.app.info("Chelka завершается")
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
