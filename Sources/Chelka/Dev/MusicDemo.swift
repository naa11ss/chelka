import AppKit
import ChelkaCore

/// `Chelka --music-demo` — проверка музыкального модуля.
///
/// Специально не запускает плееры и не включает воспроизведение: проверять
/// работу виджета, начав играть музыку на чужой машине, — плохая идея.
/// Проверяется то, что можно проверить тихо: мост к AppleScript, таймауты,
/// отказ будить закрытые приложения и разбор состояния.
@MainActor
enum MusicDemo {

    static func run(service: MusicService) {
        var failures = 0

        func check(_ label: String, _ condition: Bool, detail: String = "") {
            if !condition { failures += 1 }
            print("\(condition ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        print("проверка музыкального модуля")
        print("")

        // 1. Мост вообще работает.
        let echo = AppleScriptBridge.run("return \"пинг\"")
        check("AppleScript отвечает", echo == .success("пинг"), detail: String(describing: echo))

        // 2. Зависший скрипт снимается по таймауту, а не вешает виджет.
        let started = Date()
        let hung = AppleScriptBridge.run("delay 5", timeout: 0.8)
        let elapsed = Date().timeIntervalSince(started)
        check("зависший скрипт снимается по таймауту",
              hung == .failure(.timedOut) && elapsed < 2.0,
              detail: String(format: "%.2f с, результат %@", elapsed, String(describing: hung)))

        // 3. Закрытые плееры не будятся опросом.
        let runningBefore = MusicSource.allCases.filter { AppleScriptBridge.isRunning(bundleID: $0.bundleID) }
        service.refresh()
        settle(1.5)
        let runningAfter = MusicSource.allCases.filter { AppleScriptBridge.isRunning(bundleID: $0.bundleID) }

        check("опрос не запускает закрытые плееры",
              runningBefore.map(\.rawValue) == runningAfter.map(\.rawValue),
              detail: runningAfter.isEmpty ? "запущенных плееров нет" : runningAfter.map(\.displayName).joined(separator: ", "))

        // 4. Состояние соответствует обстановке.
        if runningAfter.isEmpty {
            check("без плееров сообщается о запасном пути",
                  service.status == .noSupportedPlayer,
                  detail: String(describing: service.status))
            check("трека нет", service.nowPlaying == nil)
        } else {
            check("плеер опрошен",
                  service.status == .connected || service.status != .idle,
                  detail: String(describing: service.status))
            if let playing = service.nowPlaying {
                print("    сейчас: \(playing.artist) — \(playing.title) (\(playing.source.displayName))")
                check("длительность разобрана", playing.duration > 0,
                      detail: TimeFormatting.trackTime(playing.duration))
            }
        }

        // 5. Опрос обязан останавливаться.
        service.startPolling(interval: 0.5)
        settle(0.3)
        let wasPolling = service.isPolling
        service.stopPolling()
        check("опрос запускается и останавливается", wasPolling && !service.isPolling)

        // 6. Медиа-клавиши: сообщаем состояние, не требуем.
        print("")
        print("медиа-клавиши: \(MediaKeys.isAuthorized ? "разрешены" : "нужен «Универсальный доступ»")")
        print("плееры: \(runningAfter.isEmpty ? "не запущены" : runningAfter.map(\.displayName).joined(separator: ", "))")

        print("")
        print(failures == 0 ? "проверка пройдена" : "провалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
