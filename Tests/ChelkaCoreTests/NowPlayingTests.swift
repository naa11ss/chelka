import Foundation
import Testing

@testable import ChelkaCore

private func track(
    source: MusicSource = .spotify,
    id: String = "t1",
    playing: Bool = true,
    duration: TimeInterval = 200,
    position: TimeInterval = 50,
    sampledAt: TimeInterval = 1000
) -> NowPlaying {
    NowPlaying(
        source: source,
        trackID: id,
        title: "Название",
        artist: "Исполнитель",
        album: "Альбом",
        isPlaying: playing,
        duration: duration,
        position: position,
        sampledAt: sampledAt
    )
}

@Suite("Что играет")
struct NowPlayingTests {

    @Test("Во время воспроизведения позиция достраивается по часам")
    func positionAdvancesWhilePlaying() {
        let playing = track(playing: true, position: 50, sampledAt: 1000)
        #expect(playing.position(at: 1010) == 60)
    }

    @Test("На паузе позиция не двигается")
    func positionFrozenWhilePaused() {
        let paused = track(playing: false, position: 50, sampledAt: 1000)
        #expect(paused.position(at: 1060) == 50)
    }

    @Test("Позиция не выходит за длительность трека")
    func positionClampedToDuration() {
        let playing = track(playing: true, duration: 100, position: 95, sampledAt: 1000)
        #expect(playing.position(at: 2000) == 100)
    }

    @Test("Прогресс — доля от нуля до единицы")
    func progressIsFraction() {
        let playing = track(playing: false, duration: 200, position: 50)
        #expect(playing.progress(at: 1000) == 0.25)
    }

    @Test("Нулевая длительность не приводит к делению на ноль")
    func zeroDurationIsSafe() {
        let stream = track(duration: 0, position: 30)
        #expect(stream.progress(at: 1000) == 0)
        #expect(stream.position(at: 1010) == 40)
    }

    @Test("Один трек узнаётся по источнику и идентификатору")
    func sameTrackDetection() {
        let first = track(id: "a", position: 10)
        let later = track(id: "a", position: 90)
        let other = track(id: "b")
        let otherApp = track(source: .appleMusic, id: "a")

        #expect(later.isSameTrack(as: first))
        #expect(!other.isSameTrack(as: first))
        #expect(!otherApp.isSameTrack(as: first))
        #expect(!first.isSameTrack(as: nil))
    }
}

@Suite("Выбор источника музыки")
struct NowPlayingSelectionTests {

    @Test("Играющий важнее поставленного на паузу")
    func playingWinsOverPaused() {
        let paused = track(source: .appleMusic, id: "m", playing: false, sampledAt: 2000)
        let playing = track(source: .spotify, id: "s", playing: true, sampledAt: 1000)

        #expect(NowPlayingSelection.best(from: [paused, playing])?.source == .spotify)
    }

    @Test("Среди играющих берётся самый свежий замер")
    func freshestPlayingWins() {
        let old = track(source: .appleMusic, id: "m", playing: true, sampledAt: 1000)
        let fresh = track(source: .spotify, id: "s", playing: true, sampledAt: 1500)

        #expect(NowPlayingSelection.best(from: [old, fresh])?.source == .spotify)
    }

    @Test("Если все на паузе — показываем самый свежий")
    func allPausedFallsBackToFreshest() {
        let old = track(source: .appleMusic, id: "m", playing: false, sampledAt: 1000)
        let fresh = track(source: .spotify, id: "s", playing: false, sampledAt: 1500)

        #expect(NowPlayingSelection.best(from: [old, fresh])?.source == .spotify)
    }

    @Test("Пустой список — ничего не играет")
    func emptyMeansNothing() {
        #expect(NowPlayingSelection.best(from: []) == nil)
    }
}

@Suite("Формат времени трека")
struct TimeFormattingTests {

    @Test("Минуты и секунды")
    func minutesAndSeconds() {
        #expect(TimeFormatting.trackTime(0) == "0:00")
        #expect(TimeFormatting.trackTime(7) == "0:07")
        #expect(TimeFormatting.trackTime(187) == "3:07")
    }

    @Test("Часы появляются только когда нужны")
    func hoursOnlyWhenNeeded() {
        #expect(TimeFormatting.trackTime(3599) == "59:59")
        #expect(TimeFormatting.trackTime(3753) == "1:02:33")
    }

    @Test("Мусорные значения не ломают формат")
    func garbageInputIsSafe() {
        #expect(TimeFormatting.trackTime(-5) == "0:00")
        #expect(TimeFormatting.trackTime(.nan) == "0:00")
        #expect(TimeFormatting.trackTime(.infinity) == "0:00")
    }
}
