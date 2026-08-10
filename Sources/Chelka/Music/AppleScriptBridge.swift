import AppKit
import ChelkaCore

/// Запуск AppleScript с жёстким таймаутом.
///
/// Почему отдельным процессом, а не `NSAppleScript`: подвисший плеер
/// подвешивает и скрипт. `NSAppleScript` в этом случае занимает поток
/// намертво, а внешний процесс можно просто убить. Виджет обязан
/// пережить залипший Music.app, а не залипнуть вместе с ним.
enum AppleScriptBridge {

    enum Failure: Error, Equatable {
        /// Пользователь не дал разрешение на управление приложением.
        case automationDenied
        case timedOut
        case scriptError(String)
        case appNotRunning
    }

    enum Outcome: Equatable {
        case success(String)
        case failure(Failure)
    }

    /// Приложение запущено? Скрипт `tell application` запускает приложение,
    /// если оно закрыто — спрашивать состояние у закрытого плеера нельзя,
    /// иначе виджет сам будет открывать Music при каждом опросе.
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func run(_ script: String, timeout: TimeInterval = 2.0) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(.scriptError("не удалось запустить osascript: \(error)"))
        }

        // Читаем в фоне: заполненный буфер трубы остановил бы процесс,
        // и таймаут сработал бы на пустом месте.
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }

        if process.isRunning {
            process.terminate()
            if group.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                // SIGTERM — вежливая просьба, её можно проигнорировать
                // (системный диалог, по-настоящему зависший процесс).
                // SIGKILL нельзя ни перехватить, ни отложить — после него
                // труба гарантированно закроется, и фоновые читатели
                // (`readDataToEndOfFile`) разблокируются, а не останутся
                // висеть в фоне до следующего перезапуска приложения.
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 0.3)
            }
            Log.media.error("скрипт не ответил за \(timeout, format: .fixed(precision: 1)) с — процесс снят")
            return .failure(.timedOut)
        }

        _ = group.wait(timeout: .now() + 0.5)

        let stdout = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            return .failure(classify(stderr))
        }
        return .success(stdout)
    }

    /// Разбор ошибок osascript. Отказ в разрешении надо отличать от поломки:
    /// в первом случае пользователю нужно объяснить, куда нажать.
    private static func classify(_ stderr: String) -> Failure {
        // -1743 — «не разрешено отправлять команды приложению».
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not allowed") {
            return .automationDenied
        }
        // -600 — приложение не запущено.
        if stderr.contains("-600") {
            return .appNotRunning
        }
        return .scriptError(stderr.isEmpty ? "неизвестная ошибка" : stderr)
    }
}
