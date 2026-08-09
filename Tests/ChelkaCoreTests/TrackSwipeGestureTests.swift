import Testing

@testable import ChelkaCore

@Suite("Жест переключения трека")
struct TrackSwipeGestureTests {

    @Test("Свайп влево (отрицательная дельта) даёт «следующий»")
    func leftSwipeMeansNext() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()

        gesture.changed(deltaX: -20)
        gesture.changed(deltaX: -20)
        let result = gesture.changed(deltaX: -30)

        #expect(result == .next)
    }

    @Test("Свайп вправо (положительная дельта) даёт «предыдущий»")
    func rightSwipeMeansPrevious() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()

        gesture.changed(deltaX: 40)
        let result = gesture.changed(deltaX: 30)

        #expect(result == .previous)
    }

    @Test("Ниже порога решения нет")
    func belowThresholdNoDecision() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()

        #expect(gesture.changed(deltaX: -10) == nil)
        #expect(gesture.changed(deltaX: 15) == nil)
    }

    @Test("Срабатывает один раз за жест, даже если дельты продолжают идти")
    func firesOnceUntilNextGesture() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()

        #expect(gesture.changed(deltaX: -70) == .next)
        // Инерционные события после срабатывания не должны перелистывать дальше.
        #expect(gesture.changed(deltaX: -70) == nil)
        #expect(gesture.changed(deltaX: -70) == nil)
    }

    @Test("Новый жест сбрасывает состояние")
    func newGestureResets() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()
        #expect(gesture.changed(deltaX: -70) == .next)

        gesture.began()
        #expect(gesture.changed(deltaX: -70) == .next)
    }

    @Test("Жест без пересечения порога завершается без решения")
    func endsWithoutFiring() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()
        _ = gesture.changed(deltaX: -20)
        gesture.ended()

        #expect(gesture.changed(deltaX: -20) == nil)
    }

    @Test("Дельты вне отслеживания игнорируются")
    func ignoresDeltasOutsideTracking() {
        var gesture = TrackSwipeGesture(threshold: 60)
        // began() ещё не вызван.
        #expect(gesture.changed(deltaX: -100) == nil)
    }

    @Test("Смена направления внутри жеста считает по чистому накоплению")
    func accumulatesAlgebraically() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()

        _ = gesture.changed(deltaX: -50)
        // Возврат почти всей дистанции — суммарно (-5) ниже порога.
        #expect(gesture.changed(deltaX: 45) == nil)
        // Теперь уверенно вправо: -5 + 70 = 65 ≥ 60.
        #expect(gesture.changed(deltaX: 70) == .previous)
    }

    @Test("Ровно на пороге уже срабатывает")
    func exactThresholdFires() {
        var gesture = TrackSwipeGesture(threshold: 60)
        gesture.began()
        #expect(gesture.changed(deltaX: -60) == .next)
    }

    @Test("Настраиваемый порог применяется")
    func customThreshold() {
        var gesture = TrackSwipeGesture(threshold: 10)
        gesture.began()
        #expect(gesture.changed(deltaX: -5) == nil)
        #expect(gesture.changed(deltaX: -6) == .next)
    }
}
