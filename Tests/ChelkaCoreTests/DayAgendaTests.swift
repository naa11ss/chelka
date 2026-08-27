import Foundation
import Testing

@testable import ChelkaCore

/// Полдень условного дня — от него отсчитываются все проверки.
private let noon = Date(timeIntervalSince1970: 1_700_000_000)

private func event(
    _ title: String,
    startsIn minutes: Double,
    lasts duration: Double = 60,
    allDay: Bool = false
) -> AgendaEvent {
    let start = noon.addingTimeInterval(minutes * 60)
    return AgendaEvent(
        id: title,
        title: title,
        start: start,
        end: start.addingTimeInterval(duration * 60),
        isAllDay: allDay
    )
}

@Suite("Повестка дня")
struct DayAgendaTests {

    @Test("Идущее сейчас идёт первым, прошедшее — последним")
    func orderPutsCurrentFirst() {
        let events = [
            event("прошло", startsIn: -180),
            event("позже", startsIn: 120),
            event("идёт", startsIn: -10, lasts: 60),
        ]

        let titles = DayAgenda.ordered(events, now: noon).map(\.title)
        #expect(titles == ["идёт", "позже", "прошло"])
    }

    @Test("Событие на весь день не считается идущим и не вытесняет встречу")
    func allDayDoesNotOutrankRunning() {
        let events = [
            event("весь день", startsIn: -600, lasts: 1440, allDay: true),
            event("идёт", startsIn: -5, lasts: 30),
        ]

        #expect(DayAgenda.ordered(events, now: noon).first?.title == "идёт")
        #expect(DayAgenda.current(events, now: noon)?.title == "идёт")
    }

    @Test("Прошедшее упорядочено от свежего к старому")
    func pastOrderedNewestFirst() {
        let events = [
            event("давно", startsIn: -600),
            event("недавно", startsIn: -120),
        ]

        #expect(DayAgenda.ordered(events, now: noon).map(\.title) == ["недавно", "давно"])
    }

    @Test("Ближайшее будущее находится, прошедшее в него не попадает")
    func nextSkipsPast() {
        let events = [
            event("прошло", startsIn: -60),
            event("через час", startsIn: 60),
            event("через полчаса", startsIn: 30),
        ]

        #expect(DayAgenda.next(events, now: noon)?.title == "через полчаса")
    }

    @Test("Идущее сейчас не предлагается как «ближайшее»")
    func nextSkipsRunning() {
        let events = [event("идёт", startsIn: -10, lasts: 60)]
        #expect(DayAgenda.next(events, now: noon) == nil)
    }

    @Test("Пустой день не выдумывает событий")
    func emptyDay() {
        #expect(DayAgenda.ordered([], now: noon).isEmpty)
        #expect(DayAgenda.current([], now: noon) == nil)
        #expect(DayAgenda.next([], now: noon) == nil)
    }

    @Test("Время до начала считается в минутах и часах")
    func startsInFormatting() {
        #expect(DayAgenda.startsIn(event("x", startsIn: 25), now: noon) == "через 25 мин")
        #expect(DayAgenda.startsIn(event("x", startsIn: 120), now: noon) == "через 2 ч")
        #expect(DayAgenda.startsIn(event("x", startsIn: 90), now: noon) == "через 1 ч 30 мин")
    }

    @Test("Для уже начавшегося времени до начала нет")
    func startsInNilForPast() {
        #expect(DayAgenda.startsIn(event("x", startsIn: -5), now: noon) == nil)
    }

    @Test("Идущее прямо сейчас распознаётся по границам")
    func runningBoundaries() {
        let running = event("x", startsIn: 0, lasts: 30)
        #expect(running.isRunning(at: noon))
        // Конец не включается: встреча, которая только что закончилась,
        // уже не «идёт», иначе виджет держал бы её на первом месте.
        #expect(!running.isRunning(at: noon.addingTimeInterval(30 * 60)))
        #expect(running.isOver(at: noon.addingTimeInterval(30 * 60)))
    }
}
