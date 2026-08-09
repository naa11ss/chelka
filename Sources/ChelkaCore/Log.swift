import Foundation
import OSLog

/// Единая точка логирования. Категории разделены, чтобы в Console.app
/// можно было отфильтровать конкретную подсистему во время отладки.
public enum Log {
    public static let subsystem = "com.ivan.chelka"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let notch = Logger(subsystem: subsystem, category: "notch")
    public static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    public static let metrics = Logger(subsystem: subsystem, category: "metrics")
    public static let media = Logger(subsystem: subsystem, category: "media")
}

/// Пишет фатальные события в файл, чтобы падение можно было разобрать
/// после перезапуска, а не только по «оно закрылось».
public enum CrashReporter {
    public static var logFileURL: URL {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chelka", isDirectory: true)
        return dir.appendingPathComponent("crash.log")
    }

    public static func install() {
        // Обработчик обязан быть C-совместимой функцией без захвата контекста,
        // поэтому он вынесен на уровень файла.
        NSSetUncaughtExceptionHandler(chelkaUncaughtExceptionHandler)
    }

    public static func append(_ message: String) {
        let url = logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let data = message.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// C-совместимый обработчик необработанных исключений.
/// Отдельная функция файла — замыкание с захватом контекста
/// не приводится к указателю на функцию.
private func chelkaUncaughtExceptionHandler(_ exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    Log.app.fault("uncaught exception: \(exception.name.rawValue, privacy: .public)")
    CrashReporter.append(
        """
        [\(Date())] UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "-")
        \(stack)

        """
    )
}
