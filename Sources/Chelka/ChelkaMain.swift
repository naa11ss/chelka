import AppKit
import ChelkaCore

@main
enum ChelkaMain {
    /// Делегат держим статически: без сильной ссылки его освободит ARC
    /// сразу после `main()`, и приложение молча останется без контроллеров.
    private static let delegate = AppDelegate()

    static func main() {
        CrashReporter.install()

        let app = NSApplication.shared

        // Служебный режим: рендер видов в PNG и выход. Приложение при этом
        // не показывается и не трогает пользовательский сеанс.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let output = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : "./snapshots"
            app.setActivationPolicy(.prohibited)
            SnapshotTool.run(outputDirectory: output)
        }

        if CommandLine.arguments.contains("--diagnose") {
            app.setActivationPolicy(.prohibited)
            Diagnostics.run()
        }

        app.delegate = delegate
        // .accessory — нет иконки в доке, нет пункта в переключателе приложений.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
