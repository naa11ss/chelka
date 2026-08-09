import AppKit
import ChelkaCore

/// `Chelka --diagnose` — печатает, что приложение реально увидело на этой машине:
/// экраны, вырез, посчитанную раскладку. Первый инструмент при разборе
/// «у меня виджет не там» — без него пришлось бы гадать по скриншотам.
@MainActor
enum Diagnostics {

    static func run() -> Never {
        print("Chelka \(AppInfo.versionString)")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")

        let screens = NSScreen.screens
        print("Экранов: \(screens.count)")

        for (index, screen) in screens.enumerated() {
            let metrics = screen.chelkaMetrics
            let layout = NotchGeometry.layout(for: metrics)
            let mark = screen === NSScreen.chelkaTarget ? " ← виджет здесь" : ""

            print("")
            print("[\(index)] \(screen.localizedName)\(mark)")
            print("    frame:        \(short(metrics.frame))")
            print("    safeAreaTop:  \(metrics.safeAreaTop)")
            print("    aux left/right: \(describe(metrics.auxiliaryLeftWidth)) / \(describe(metrics.auxiliaryRightWidth))")
            print("    menuBar:      \(metrics.menuBarHeight)")
            print("    backingScale: \(screen.backingScaleFactor)")
            print("    тип:          \(layout.kind)")
            print("    свёрнутый:    \(short(layout.collapsedRectScreen))")
            print("    раскрытый:    \(short(layout.expandedRectScreen))")
            print("    зона наведения: \(short(layout.hoverRectScreen))")
            print("    панель:       \(short(layout.panelFrame))")
        }

        exit(0)
    }

    private static func short(_ rect: CGRect) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }

    private static func describe(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "нет"
    }
}
