import AppKit
import ChelkaCore

@main
enum ChelkaMain {
    /// Делегат держим статически: без сильной ссылки его освободит ARC
    /// сразу после `main()`, и приложение молча останется без контроллеров.
    private static let delegate = AppDelegate()

    static func main() {
        // Привилегированная запись в SMC: этот же бинарник, перезапущенный
        // под root через osascript (см. PrivilegedFanWriter) — проверяем
        // до старта AppKit, этот путь не показывает никакого интерфейса.
        if let index = CommandLine.arguments.firstIndex(of: "--smc-fan-daemon"),
           CommandLine.arguments.count > index + 2 {
            PrivilegedFanWriter.runDaemon(cmdPath: CommandLine.arguments[index + 1], respPath: CommandLine.arguments[index + 2])
        }

        CrashReporter.install()

        let app = NSApplication.shared

        // Служебный режим: рендер видов в PNG и выход. Приложение при этом
        // не показывается и не трогает пользовательский сеанс.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let output = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : "./snapshots"
            app.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { SnapshotTool.run(outputDirectory: output) }
        }

        if CommandLine.arguments.contains("--diagnose") {
            app.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { Diagnostics.run() }
        }

        app.delegate = delegate
        // .accessory — нет иконки в доке, нет пункта в переключателе приложений.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
