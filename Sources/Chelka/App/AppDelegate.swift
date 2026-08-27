import AppKit
import ChelkaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeController: ThemeController!
    private var widgetSizeController: WidgetSizeController!
    private var clipboardService: ClipboardService!
    private var fileShelfService: FileShelfService!
    private var eventMonitor: SystemEventMonitor!
    private var deviceBatteryReader: DeviceBatteryReader!
    private var metricsService: MetricsService!
    private var musicService: MusicService!
    private var notchController: NotchController!
    private var permissionsService: PermissionsService!
    private var settingsWindow: SettingsWindowController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Chelka запущена, версия \(AppInfo.versionString, privacy: .public)")

        themeController = ThemeController()
        widgetSizeController = WidgetSizeController()
        clipboardService = ClipboardService()
        fileShelfService = FileShelfService()
        eventMonitor = SystemEventMonitor()
        deviceBatteryReader = DeviceBatteryReader()
        metricsService = MetricsService()
        // Настройки общие: разрешение ходить в сеть за обложкой лежит там же.
        musicService = MusicService(settings: clipboardService.settings)
        notchController = NotchController(
            theme: themeController,
            widgetSize: widgetSizeController,
            clipboard: clipboardService,
            files: fileShelfService,
            metrics: metricsService,
            music: musicService,
            devices: deviceBatteryReader,
            events: eventMonitor
        )
        permissionsService = PermissionsService(clipboard: clipboardService, music: musicService)
        settingsWindow = SettingsWindowController(
            theme: themeController,
            widgetSize: widgetSizeController,
            clipboard: clipboardService,
            permissions: permissionsService
        )
        statusItemController = StatusItemController(
            theme: themeController,
            onToggleNotch: { [weak self] in self?.notchController.toggleFromMenu() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )

        // Виджет должен знать, где стоит значок, до первого показа.
        notchController.anchorProvider = { [weak self] in self?.statusItemController.buttonScreenFrame }

        clipboardService.start()
        musicService.start()
        eventMonitor.start()
        notchController.start()

        // ⌥⌘V открывает виджет на истории буфера.
        HotkeyCenter.shared.register(HotkeyCenter.defaultBinding) { [weak self] in
            self?.notchController.openPinned()
        }

        scheduleDemosIfRequested()
    }

    /// Запуск сценарных проверок.
    ///
    /// Именно таймером, а не блоком главной очереди: проверки крутят
    /// вложенный цикл событий, ожидая результатов, а изнутри блока главной
    /// очереди следующие блоки той же очереди выполниться не могут —
    /// она занята текущим. Из обработчика таймера очередь свободна.
    private func scheduleDemosIfRequested() {
        let demos: [(flag: String, delay: TimeInterval, run: @MainActor () -> Void)] = [
            ("--music-demo", 0.3, { [weak self] in MusicDemo.run(service: self!.musicService) }),
            ("--metrics-demo", 0.3, { [weak self] in MetricsDemo.run(service: self!.metricsService) }),
            ("--clipboard-demo", 1.2, { [weak self] in ClipboardDemo.run(service: self!.clipboardService) }),
            ("--hover-demo", 0.3, { [weak self] in HoverDemo.run(controller: self!.notchController) }),
            ("--settings-demo", 0.3, { [weak self] in
                guard let self else { return }
                SettingsDemo.run(
                    window: self.settingsWindow,
                    theme: self.themeController,
                    widgetSize: self.widgetSizeController,
                    clipboard: self.clipboardService,
                    permissions: self.permissionsService
                )
            }),
        ]

        for demo in demos where CommandLine.arguments.contains(demo.flag) {
            Timer.scheduledTimer(withTimeInterval: demo.delay, repeats: false) { _ in
                MainActor.assumeIsolated { demo.run() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ручной режим вентилятора не должен пережить процесс, который
        // его выставил — иначе обороты застынут там, где их оставили,
        // даже когда машина остынет.
        metricsService?.revertAllFanOverrides()
        PrivilegedFanWriter.shutdown()
        clipboardService?.stop()
        musicService?.stop()
        eventMonitor?.stop()
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
