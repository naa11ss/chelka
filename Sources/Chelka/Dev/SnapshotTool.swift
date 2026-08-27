import AppKit
import SwiftUI
import ChelkaCore

/// Офлайн-рендер видов виджета в PNG: `Chelka --snapshot <папка>`.
///
/// Нужен, чтобы проверять внешний вид детерминированно — в обеих темах,
/// в обоих состояниях и на обоих типах экранов — без живого монитора,
/// без разрешения «Запись экрана» и без человека у клавиатуры.
/// Тот же механизм годится для визуальных регрессий в CI.
@MainActor
enum SnapshotTool {

    /// `true` пока идёт офлайн-рендер снимков — читается видами, которым
    /// нужно вести себя иначе без работающего display link (см.
    /// `NotchEventPill.reveal`, где обычная `withAnimation` не долетает
    /// до финального кадра в этом режиме).
    static private(set) var isRendering = false

    struct Case {
        let name: String
        let metrics: ScreenMetrics
        let state: NotchState
        let appearance: NSAppearance.Name
    }

    /// MacBook Air M2 при масштабе «больше места»: 1710×1112 pt, вырез 209×38.
    /// Значения сняты с живой машины через `--diagnose`.
    static let builtIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        safeAreaTop: 38,
        auxiliaryLeftWidth: 751,
        auxiliaryRightWidth: 750,
        menuBarHeight: 22
    )

    /// Внешний монитор без выреза.
    static let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil,
        menuBarHeight: 24
    )

    static var cases: [Case] {
        var result: [Case] = []
        for (screenName, metrics) in [("notch", builtIn), ("nonotch", external)] {
            for (stateName, state) in [("collapsed", NotchState.collapsed), ("expanded", .expanded)] {
                for (themeName, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    result.append(
                        Case(
                            name: "\(screenName)-\(stateName)-\(themeName)",
                            metrics: metrics,
                            state: state,
                            appearance: appearance
                        )
                    )
                }
            }
        }
        return result
    }

    static func run(outputDirectory: String) -> Never {
        isRendering = true

        // Метрики снимаем настоящие: прочерки на снимках в документации
        // выглядят как неработающая функция.
        demoMetrics.startSampling(interval: 0.3)
        // И музыку тоже: прочерки в документации выглядят как неработающая
        // функция, хотя всё работает.
        demoMusic.startPolling(interval: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let directory = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var failures = 0
        for testCase in cases {
            let url = directory.appendingPathComponent("\(testCase.name).png")
            if render(testCase, to: url) {
                print("✓ \(url.lastPathComponent)")
            } else {
                failures += 1
                print("✗ \(url.lastPathComponent)")
            }
        }

        print(failures == 0 ? "снимки готовы: \(directory.path)" : "ошибок: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Один общий сервис на все снимки: пересоздавать демо-данные
    /// для каждого кадра незачем.
    private static let demoClipboard = ClipboardService.makeDemo()
    /// Отдельный домен настроек: снимки не должны показывать — и тем более
    /// трогать — настоящую полку файлов пользователя.
    private static let demoFiles = FileShelfService(defaults: UserDefaults(suiteName: "chelka.demo")!)
    private static let demoMetrics = MetricsService()
    private static let demoMusic = MusicService(settings: ClipboardSettings())
    /// Не запускается: снимкам не нужны настоящие события питания и сети,
    /// а плашка рисуется только когда событие есть.
    private static let demoEvents = SystemEventMonitor()
    /// Не опрашивается: снимки не должны зависеть от того, какие наушники
    /// подключены к машине, на которой их рендерят.
    /// Не активируется: снимки не должны трогать настоящий календарь
    /// пользователя и тем более просить у него доступ.
    private static let demoCalendar = CalendarService()
    private static let demoDevices: DeviceBatteryReader = {
        let reader = DeviceBatteryReader()
        reader.injectForPreview([
            DeviceBattery(name: "AirPods Pro", left: 100, right: 95, caseLevel: 51)
        ])
        return reader
    }()

    private static func render(_ testCase: Case, to url: URL) -> Bool {
        let layout = NotchGeometry.layout(for: testCase.metrics)
        let model = NotchViewModel(layout: layout)
        model.state = testCase.state

        let size = layout.panelFrame.size
        let root = SnapshotBackdrop {
            NotchRootView(model: model, clipboard: demoClipboard, files: demoFiles, metrics: demoMetrics, music: demoMusic, devices: demoDevices, calendar: demoCalendar, events: demoEvents)
        }

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: testCase.appearance)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Один оборот цикла: SwiftUI успевает построить дерево слоёв
        // и выполнить синхронные onAppear-обработчики до того, как мы
        // снимаем растр. Анимированные переходы снимка не дожидаются —
        // виды, которым это важно, сами проверяют `SnapshotTool.isRendering`
        // и в этом режиме проставляют финальное значение без анимации
        // (см. `NotchEventPill.reveal`).
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

/// Подложка под снимок: имитирует обои и полосу меню-бара,
/// иначе светлую тему не отличить от прозрачного фона.
private struct SnapshotBackdrop<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.19, blue: 0.28), Color(red: 0.34, green: 0.26, blue: 0.38)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
        }
    }
}
