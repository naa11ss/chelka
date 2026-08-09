import AppKit
import ChelkaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeController: ThemeController!
    private var notchController: NotchController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Chelka запущена, версия \(AppInfo.versionString, privacy: .public)")

        themeController = ThemeController()
        notchController = NotchController(theme: themeController)
        statusItemController = StatusItemController(
            theme: themeController,
            onToggleNotch: { [weak self] in self?.notchController.toggleFromMenu() }
        )

        notchController.start()

        if CommandLine.arguments.contains("--hover-demo") {
            // Даём панели встать на место, потом прогоняем сценарий.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [notchController] in
                HoverDemo.run(controller: notchController!)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
