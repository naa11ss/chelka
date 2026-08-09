import AppKit
import ChelkaCore

/// `Chelka --hover-demo` — прогоняет виджет по сценарию движений курсора
/// и печатает, что получилось, сверяя с ожиданиями.
///
/// Зачем: синтезировать настоящие события мыши нельзя без разрешения
/// «Универсальный доступ», а связку «позиция курсора → машина состояний →
/// панель → вид» проверять надо на каждом изменении. Демо подаёт позиции
/// напрямую в контроллер, минуя систему ввода.
@MainActor
enum HoverDemo {

    struct Step {
        let label: String
        /// Точка в долях от свёрнутого/раскрытого прямоугольника.
        let point: (NotchLayout) -> NSPoint
        let holdSeconds: TimeInterval
        let expected: NotchState
    }

    static let steps: [Step] = [
        Step(
            label: "далеко от выреза",
            point: { layout in NSPoint(x: layout.panelFrame.minX - 200, y: layout.panelFrame.minY - 200) },
            holdSeconds: 0.5,
            expected: .collapsed
        ),
        Step(
            label: "быстрый пролёт через вырез (короче задержки)",
            point: { layout in NSPoint(x: layout.collapsedRectScreen.midX, y: layout.collapsedRectScreen.midY) },
            holdSeconds: 0.12,
            expected: .collapsed
        ),
        Step(
            label: "сразу ушёл — раскрытия быть не должно",
            point: { layout in NSPoint(x: layout.panelFrame.maxX + 300, y: layout.panelFrame.minY - 100) },
            holdSeconds: 0.6,
            expected: .collapsed
        ),
        Step(
            label: "завис на вырезе — должно раскрыться",
            point: { layout in NSPoint(x: layout.collapsedRectScreen.midX, y: layout.collapsedRectScreen.midY) },
            holdSeconds: 0.9,
            expected: .expanded
        ),
        Step(
            label: "спустился в тело виджета — остаётся раскрытым",
            point: { layout in NSPoint(x: layout.expandedRectScreen.midX, y: layout.expandedRectScreen.midY) },
            holdSeconds: 0.9,
            expected: .expanded
        ),
        Step(
            label: "край раскрытого виджета — всё ещё раскрыт",
            point: { layout in NSPoint(x: layout.expandedRectScreen.minX + 4, y: layout.expandedRectScreen.minY + 4) },
            holdSeconds: 0.9,
            expected: .expanded
        ),
        Step(
            label: "ушёл совсем — должно свернуться",
            point: { layout in NSPoint(x: layout.panelFrame.minX - 300, y: layout.panelFrame.minY - 300) },
            holdSeconds: 0.9,
            expected: .collapsed
        ),
    ]

    static func run(controller: NotchController) {
        let layout = controller.currentLayout
        print("сценарий наведения, тип выреза: \(layout.kind)")
        print("")

        var failures = 0

        for step in steps {
            let point = step.point(layout)
            // Таймер дозревания опрашивает тот же источник — иначе он
            // подставит реальный курсор и перебьёт сценарий.
            controller.cursorProvider = { point }
            controller.simulateCursor(at: point)

            // Даём таймеру дозреть: решение о переходе принимается по задержке,
            // а не мгновенно.
            let deadline = Date().addingTimeInterval(step.holdSeconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                controller.simulateCursor(at: point)
            }

            let actual = controller.currentState
            let ok = actual == step.expected
            if !ok { failures += 1 }

            print("\(ok ? "✓" : "✗") \(step.label)")
            print("    курсор (\(Int(point.x)), \(Int(point.y))) → \(actual), ожидалось \(step.expected)")
        }

        print("")
        print(failures == 0 ? "сценарий пройден" : "провалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
