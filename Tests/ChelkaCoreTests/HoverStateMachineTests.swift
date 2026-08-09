import Foundation
import Testing

@testable import ChelkaCore

// Монотонная метка: машина принимает секунды, а не Date.
private let t0: TimeInterval = 1_000

@Suite("Дребезг наведения")
struct HoverStateMachineTests {

    @Test("Курсор внутри дольше задержки — раскрываем")
    func opensAfterDelay() {
        var sm = HoverStateMachine()

        #expect(sm.update(inside: true, now: t0) == .collapsed)
        #expect(sm.update(inside: true, now: t0 + 0.2) == .collapsed)
        #expect(sm.update(inside: true, now: t0 + 0.25) == .expanded)
    }

    @Test("Быстрый проход мимо выреза не раскрывает виджет")
    func ignoresQuickFlyBy() {
        var sm = HoverStateMachine()

        sm.update(inside: true, now: t0)
        sm.update(inside: true, now: t0 + 0.1)
        // Курсор ушёл раньше, чем истекла задержка.
        #expect(sm.update(inside: false, now: t0 + 0.15) == .collapsed)
        // И даже спустя время не должен внезапно раскрыться.
        #expect(sm.update(inside: false, now: t0 + 1.0) == .collapsed)
    }

    @Test("Возврат курсора отменяет отложенное сворачивание")
    func returningCursorCancelsClose() {
        var sm = HoverStateMachine(state: .expanded)

        sm.update(inside: false, now: t0)
        sm.update(inside: false, now: t0 + 0.2)
        #expect(sm.update(inside: true, now: t0 + 0.3) == .expanded)
        // Прошло больше closeDelay с начала выхода, но переход был отменён.
        #expect(sm.update(inside: true, now: t0 + 0.9) == .expanded)
    }

    @Test("Сворачивание после closeDelay")
    func closesAfterDelay() {
        var sm = HoverStateMachine(state: .expanded)

        #expect(sm.update(inside: false, now: t0) == .expanded)
        #expect(sm.update(inside: false, now: t0 + 0.39) == .expanded)
        #expect(sm.update(inside: false, now: t0 + 0.4) == .collapsed)
    }

    @Test("Закреплённое раскрытие курсором не сворачивается")
    func pinnedIgnoresCursor() {
        var sm = HoverStateMachine()
        sm.pinOpen()

        #expect(sm.state == .expanded)
        #expect(sm.update(inside: false, now: t0) == .expanded)
        #expect(sm.update(inside: false, now: t0 + 10) == .expanded)
    }

    @Test("Снятие закрепления возвращает управление курсору")
    func unpinRestoresHover() {
        var sm = HoverStateMachine()
        sm.pinOpen()
        sm.unpin(inside: false, now: t0)

        #expect(sm.isPinned == false)
        #expect(sm.state == .expanded)
        #expect(sm.update(inside: false, now: t0 + 0.5) == .collapsed)
    }

    @Test("Принудительное сворачивание работает мгновенно и снимает закрепление")
    func forceCollapseIsImmediate() {
        var sm = HoverStateMachine()
        sm.pinOpen()
        sm.forceCollapse()

        #expect(sm.state == .collapsed)
        #expect(sm.isPinned == false)
    }

    @Test("Флаг отложенного перехода поднимается и снимается")
    func reportsPendingTransition() {
        var sm = HoverStateMachine()

        #expect(sm.hasPendingTransition == false)
        sm.update(inside: true, now: t0)
        #expect(sm.hasPendingTransition == true)
        sm.update(inside: true, now: t0 + 0.3)
        #expect(sm.state == .expanded)
        #expect(sm.hasPendingTransition == false)
    }

    @Test("Дрожание курсора на границе не вызывает мигания")
    func jitterOnBoundaryDoesNotFlicker() {
        var sm = HoverStateMachine()
        var now: TimeInterval = t0

        // 20 переключений по 50 мс — ни одно не длится дольше задержки.
        for i in 0..<20 {
            now += 0.05
            sm.update(inside: i % 2 == 0, now: now)
        }
        #expect(sm.state == .collapsed)
    }
}

@Suite("Точность времени")
struct HoverTimingPrecisionTests {

    /// Регресс: `1000.4 - 1000` в double равно `0.39999999999997726`.
    /// Без допуска переход не срабатывал на ровных интервалах,
    /// и виджет залипал в текущем состоянии до следующего движения курсора.
    @Test("Ровный интервал срабатывает несмотря на погрешность double")
    func exactIntervalTriggersDespiteFloatingPointNoise() {
        var sm = HoverStateMachine(state: .expanded)

        sm.update(inside: false, now: 1000)
        #expect(sm.update(inside: false, now: 1000.4) == .collapsed)
    }

    @Test("Допуск не превращается в преждевременный переход")
    func epsilonDoesNotFireEarly() {
        var sm = HoverStateMachine()

        sm.update(inside: true, now: 0)
        // На миллисекунду раньше срока — ещё рано.
        #expect(sm.update(inside: true, now: 0.249) == .collapsed)
    }

    @Test("Работает на реальных значениях systemUptime")
    func worksWithRealisticUptimeMagnitude() {
        var sm = HoverStateMachine()
        let uptime: TimeInterval = 987_654.321

        sm.update(inside: true, now: uptime)
        #expect(sm.update(inside: true, now: uptime + 0.25) == .expanded)
    }
}
