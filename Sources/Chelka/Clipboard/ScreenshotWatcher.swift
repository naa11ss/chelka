import AppKit
import ChelkaCore

/// Ловит файлы снимков экрана.
///
/// Снимок через ⇧⌘4 попадает не в буфер, а в файл — и без этого наблюдателя
/// такие снимки в историю бы не попадали. Папку берём из настроек системы,
/// а не считаем, что это всегда Рабочий стол.
final class ScreenshotWatcher {

    /// Новый файл снимка. Приходит на главной очереди.
    var onNewFile: ((URL) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.ivan.chelka.screenshots")
    private var seenPaths: Set<String> = []
    /// Кандидаты, для которых уже запланирована проверка готовности —
    /// отдельно от `seenPaths`, чтобы файл, ещё дописывающийся на момент
    /// первой проверки, не выпал из рассмотрения навсегда, а мог быть
    /// подхвачен следующим событием FSEvents.
    private var pendingPaths: Set<String> = []
    private var startedAt = Date()

    private(set) var directory: URL
    /// `true`, если папку нужно каждый раз при `start()` брать заново из
    /// настроек системы. `false` — папка передана явно через `init`
    /// (например, тестами) и не должна быть тихо подменена.
    private let usesSystemDirectory: Bool

    /// Расширения, которые считаем снимками. HEIC macOS не пишет,
    /// но пользователь мог поменять формат через `defaults write`.
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"]

    /// Насколько свежим должен быть файл, чтобы считаться только что созданным.
    private static let freshnessWindow: TimeInterval = 8

    init(directory: URL? = nil) {
        self.usesSystemDirectory = directory == nil
        self.directory = directory ?? Self.systemScreenshotDirectory
    }

    /// Папка снимков из настроек macOS. По умолчанию — Рабочий стол.
    static var systemScreenshotDirectory: URL {
        let value = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String

        if let value, !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func start() {
        stop()
        startedAt = Date()
        if usesSystemDirectory {
            directory = Self.systemScreenshotDirectory
        }

        // Всё, что уже лежит в папке, — не новости.
        seenPaths = Set(existingImageFiles().map(\.path))

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvents()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            Log.clipboard.error("не удалось создать наблюдатель за \(self.directory.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream

        Log.clipboard.info("наблюдаю за снимками в \(self.directory.path, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    // MARK: - Разбор событий

    /// Событие FSEvents говорит «в папке что-то поменялось», но не что именно
    /// пригодно к чтению. Поэтому сканируем папку и отбираем свежие картинки,
    /// которых раньше не видели.
    private func handleEvents() {
        let candidates = existingImageFiles().filter { url in
            guard !seenPaths.contains(url.path), !pendingPaths.contains(url.path) else { return false }
            guard let created = creationDate(of: url) else { return false }
            guard created >= startedAt.addingTimeInterval(-1) else { return false }
            return Date().timeIntervalSince(created) <= Self.freshnessWindow
        }

        guard !candidates.isEmpty else { return }
        // Помечаем как "в проверке", не как "увиденное" — файл ещё может
        // оказаться не дописанным, и тогда его нужно оставить кандидатом
        // на следующее событие FSEvents, а не потерять навсегда.
        for url in candidates { pendingPaths.insert(url.path) }

        // Снимок пишется не мгновенно: читать сразу по событию — рискуем
        // получить половину файла.
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let ready = candidates.filter { self.isReadable($0) }
            let notReady = Set(candidates.map(\.path)).subtracting(ready.map(\.path))

            for url in ready { self.pendingPaths.remove(url.path); self.seenPaths.insert(url.path) }
            // Не готов — снимаем с "в проверке", чтобы следующее событие
            // FSEvents (например, когда запись файла завершится) снова
            // рассмотрело его как кандидата, вместо того чтобы забыть о нём.
            for path in notReady { self.pendingPaths.remove(path) }

            guard !ready.isEmpty else { return }
            DispatchQueue.main.async {
                for url in ready {
                    Log.clipboard.info("новый снимок: \(url.lastPathComponent, privacy: .public)")
                    self.onNewFile?(url)
                }
            }
        }
    }

    private func existingImageFiles() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return contents.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Файл считается готовым, если размер не меняется между двумя замерами.
    private func isReadable(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let first = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, first > 0 else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.1)
        guard let second = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int else { return false }
        return first == second
    }
}
