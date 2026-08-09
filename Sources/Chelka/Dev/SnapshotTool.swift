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
        // Метрики снимаем настоящие: прочерки на снимках в документации
        // выглядят как неработающая функция.
        demoMetrics.startSampling(interval: 0.3)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

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
    private static let demoMetrics = MetricsService()
    private static let demoMusic = MusicService()

    private static func render(_ testCase: Case, to url: URL) -> Bool {
        let layout = NotchGeometry.layout(for: testCase.metrics)
        let model = NotchViewModel(layout: layout)
        model.state = testCase.state

        let size = layout.panelFrame.size
        let root = SnapshotBackdrop {
            NotchRootView(model: model, clipboard: demoClipboard, metrics: demoMetrics, music: demoMusic)
        }

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: testCase.appearance)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Один оборот цикла: SwiftUI успевает построить дерево слоёв
        // до того, как мы снимаем растр.
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
