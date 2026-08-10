import Darwin
import Foundation
import ChelkaCore

/// Запись в SMC требует root (`kIOReturnNotPrivileged` для обычного процесса —
/// проверено на реальном Intel-железе, см. Diagnostics). SMJobBless и его
/// современная замена `SMAppService` для этого не годятся: обе требуют,
/// чтобы помощника подписал настоящий Apple Developer ID — самоподписанный
/// локальный сертификат из `make-identity.sh` они не «благословляют» ни при
/// какой доработке кода.
///
/// `AuthorizationExecuteWithPrivileges` — классическая замена для случая без
/// Developer ID — в этом SDK жёстко недоступна из Swift (`unavailable`,
/// не просто deprecated), проверено напрямую компиляцией. `do shell script
/// ... with administrator privileges` и обычный `sudo -A` в теории кэшируют
/// пароль на ~5 минут между отдельными запусками — но на практике на этой
/// машине оба переспрашивают пароль на каждый вызов (проверено эмпирически
/// дважды, независимо друг от друга), и полагаться на это кэширование нельзя.
///
/// Поэтому — один привилегированный процесс на всю сессию виджета вместо
/// перезапуска на каждое движение регулятора: пароль вводится один раз,
/// чтобы поднять этот процесс, а дальше обороты передаются ему через два
/// именованных канала (`mkfifo`) — само по себе кэширование пароля системой
/// уже не требуется, потому что процесс, а не только его права, живёт всё
/// это время.
enum PrivilegedFanWriter {

    // MARK: - Клиентская сторона (вызывается из MetricsService)

    private static let session = FanDaemonSession()

    /// `nil` в `targetRPM` — вернуть вентилятор автоматике прошивки.
    static func write(index: Int, targetRPM: Double?) async -> Bool {
        await session.write(index: index, targetRPM: targetRPM)
    }

    /// Вызывать при выходе из приложения — привилегированный процесс сам
    /// завершится по EOF, когда закроются файловые дескрипторы умершего
    /// родителя, но явное `quit` быстрее и не оставляет его висеть лишнюю
    /// секунду с открытым правом записи в SMC.
    static func shutdown() {
        session.shutdown()
    }

    fileprivate static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Та же строка, но для встраивания в двойные кавычки AppleScript —
    /// экранировать нужно ДО передачи в `-e`, иначе бэкслеши из
    /// `shellQuoted` разъедут саму AppleScript, не долетев до `/bin/sh`.
    fileprivate static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Привилегированная сторона (сам процесс, перезапущенный под root)

    /// Никакой настоящий Mac-вентилятор не крутится быстрее этого — берётся
    /// с большим запасом относительно паспортных ~8000 об/мин на реальном
    /// Intel-железе (см. `chelka-intel-findings.md`). Демон не знает
    /// паспортный диапазон конкретного вентилятора (это кэширует клиент
    /// в `MetricsService`), но и без этого может отсечь заведомо
    /// бессмысленное значение до того, как оно уйдёт в SMC — тот же принцип
    /// защиты от мусора на входе, что и у строгой построчной валидации ниже.
    private static let absoluteRPMCeiling: Double = 20000

    /// Точка входа `--smc-fan-daemon <cmdFifo> <respFifo>`. Читает строки
    /// вида `"<index> <rpm|auto>"` из `cmdFifo`, отвечает `"ok"`/`"fail"`
    /// в `respFifo` на каждую. Строка `"quit"` или закрытие `cmdFifo` на
    /// другом конце завершают процесс.
    static func runDaemon(cmdPath: String, respPath: String) -> Never {
        let cmdFD = open(cmdPath, O_RDONLY)
        guard cmdFD >= 0 else { exit(1) }
        let respFD = open(respPath, O_WRONLY)
        guard respFD >= 0 else { exit(1) }

        let cmdFile = FileHandle(fileDescriptor: cmdFD, closeOnDealloc: true)
        let respFile = FileHandle(fileDescriptor: respFD, closeOnDealloc: true)
        let reader = SMCReader()
        var buffer = Data()
        let newline = Data([0x0A])

        while true {
            let chunk = cmdFile.availableData
            if chunk.isEmpty { exit(0) } // клиент закрыл трубу — сессия окончена

            buffer.append(chunk)
            while let range = buffer.range(of: newline) {
                let line = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                buffer.removeSubrange(..<range.upperBound)

                if line == "quit" { exit(0) }

                let success = Self.handle(line: line, reader: reader)
                try? respFile.write(contentsOf: Data((success ? "ok\n" : "fail\n").utf8))
            }
        }
    }

    /// Разбор ровно тот же, что раньше был в одноразовом `--smc-write-fan`:
    /// строгая проверка на входе, потому что этот код уже исполняется
    /// под root, а мусор сюда в принципе может прислать любой, кто получит
    /// доступ к именованному каналу (хотя права 0600 и приватная временная
    /// папка делают это практически невозможным для чужого процесса).
    private static func handle(line: String, reader: SMCReader) -> Bool {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let index = Int(parts[0]), (0...7).contains(index) else { return false }

        if parts[1] == "auto" {
            return reader.setFanOverride(index: index, targetRPM: nil)
        }
        guard let rpm = Double(parts[1]), rpm.isFinite, rpm >= 0, rpm <= absoluteRPMCeiling else { return false }
        return reader.setFanOverride(index: index, targetRPM: rpm)
    }
}

/// Владеет привилегированным процессом и его каналами. Один экземпляр на
/// приложение, все обращения — через последовательную очередь: `Process`
/// и файловые дескрипторы не рассчитаны на параллельный доступ, а
/// движения регулятора и так естественно сериализуются одно за другим.
private final class FanDaemonSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ivan.chelka.fan-daemon-session")
    private var process: Process?
    private var cmdWriteHandle: FileHandle?
    private var respReadHandle: FileHandle?
    private var workDir: URL?

    func write(index: Int, targetRPM: Double?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.writeLocked(index: index, targetRPM: targetRPM)) }
        }
    }

    func shutdown() {
        queue.async { self.teardownLocked(sendQuit: true) }
    }

    private func writeLocked(index: Int, targetRPM: Double?) -> Bool {
        if process?.isRunning != true {
            teardownLocked(sendQuit: false)
            guard startDaemonLocked() else { return false }
        }

        let rpmArgument = targetRPM.map { String(format: "%.3f", $0) } ?? "auto"
        guard let data = "\(index) \(rpmArgument)\n".data(using: .utf8), let cmdWriteHandle else { return false }

        do {
            try cmdWriteHandle.write(contentsOf: data)
        } catch {
            teardownLocked(sendQuit: false)
            return false
        }

        guard let respReadHandle else { return false }
        let response = respReadHandle.availableData
        guard !response.isEmpty else {
            // Пустой ответ — демон умер посреди работы (например, машина
            // заснула и разбудила SMC-соединение в плохом состоянии).
            // Следующий вызов поднимет его заново, заново спросив пароль —
            // это лучше, чем тихо считать запись успешной.
            teardownLocked(sendQuit: false)
            return false
        }
        return String(data: response, encoding: .utf8)?.hasPrefix("ok") ?? false
    }

    /// Поднимает привилегированный процесс и дожидается, пока он реально
    /// заработает — открытие `cmdFifo` на запись блокируется ровно до
    /// того момента, пока демон (уже под root) не откроет свой конец на
    /// чтение. Если пользователь отменит диалог пароля, `osascript`
    /// просто завершится — тогда не ждём полный тайм-аут, а отступаем
    /// сразу же, как только видим, что процесс уже не запущен.
    private func startDaemonLocked() -> Bool {
        guard let executablePath = Bundle.main.executablePath else { return false }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chelka-fan-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )) != nil else { return false }

        let cmdPath = dir.appendingPathComponent("cmd").path
        let respPath = dir.appendingPathComponent("resp").path
        guard mkfifo(cmdPath, 0o600) == 0, mkfifo(respPath, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: dir)
            return false
        }

        let shellCommand = "\(PrivilegedFanWriter.shellQuoted(executablePath)) --smc-fan-daemon "
            + "\(PrivilegedFanWriter.shellQuoted(cmdPath)) \(PrivilegedFanWriter.shellQuoted(respPath))"
        let script = "do shell script \"\(PrivilegedFanWriter.appleScriptQuoted(shellCommand))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return false
        }

        // Двухминутный запас на диалог пароля — человеку может понадобиться
        // время его найти и ввести, торопить незачем, но и висеть вечно,
        // если пользователь просто ушёл от компьютера, тоже не дело.
        let deadline = Date().addingTimeInterval(120)
        var cmdFD: Int32 = -1
        while Date() < deadline, process.isRunning {
            cmdFD = open(cmdPath, O_WRONLY | O_NONBLOCK)
            if cmdFD >= 0 { break }
            usleep(50_000)
        }
        guard cmdFD >= 0 else {
            process.terminate()
            try? FileManager.default.removeItem(at: dir)
            return false
        }
        // Неблокирующий режим был нужен только чтобы не зависнуть в опросе
        // выше — дальше пишем как обычно, с нормальным блокирующим поведением.
        let flags = fcntl(cmdFD, F_GETFL, 0)
        _ = fcntl(cmdFD, F_SETFL, flags & ~O_NONBLOCK)

        // По этому моменту `cmdFD >= 0` уже означает, что демон (уже под
        // root) прошёл свой блокирующий `open(cmdPath, O_RDONLY)` и сам
        // заблокирован в открытии `respPath` на запись — рандеву на второй
        // трубе не зависит от первой. `process.terminate()` шлёт SIGTERM
        // только обёртке `osascript`; реальный привилегированный процесс,
        // поднятый через "with administrator privileges", таким сигналом
        // не обязательно завершается и может остаться висеть в этом open()
        // навсегда — трубу открывать больше некому, её директория вот-вот
        // будет удалена. Несколько попыток (`EINTR` — не редкость) плюс,
        // если они не помогли, открытие `respPath` только чтобы разблокировать
        // демона и дать ему дойти до команды "quit" — надёжнее, чем разово
        // сдаться и остаться с осиротевшим root-процессом.
        var respFD: Int32 = -1
        for _ in 0..<3 {
            respFD = open(respPath, O_RDONLY)
            if respFD >= 0 { break }
        }
        guard respFD >= 0 else {
            let rescueFD = open(respPath, O_RDONLY)
            if rescueFD >= 0 {
                try? FileHandle(fileDescriptor: cmdFD, closeOnDealloc: true).write(contentsOf: Data("quit\n".utf8))
                close(rescueFD)
            } else {
                close(cmdFD)
            }
            process.terminate()
            try? FileManager.default.removeItem(at: dir)
            return false
        }

        self.process = process
        self.cmdWriteHandle = FileHandle(fileDescriptor: cmdFD, closeOnDealloc: true)
        self.respReadHandle = FileHandle(fileDescriptor: respFD, closeOnDealloc: true)
        self.workDir = dir
        return true
    }

    private func teardownLocked(sendQuit: Bool) {
        if sendQuit { try? cmdWriteHandle?.write(contentsOf: Data("quit\n".utf8)) }
        cmdWriteHandle?.closeFile()
        respReadHandle?.closeFile()
        process?.terminate()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        process = nil
        cmdWriteHandle = nil
        respReadHandle = nil
        workDir = nil
    }
}
