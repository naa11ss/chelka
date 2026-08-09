import AppKit
import ChelkaCore

/// Следит за общим буфером обмена.
///
/// Уведомлений об изменении буфера macOS не даёт — единственный способ
/// узнать о копировании — периодически сверять `changeCount`. Проверка
/// стоит один целочисленный вызов, поэтому 0.35 с не заметны на фоне,
/// но и задержка при копировании не ощущается.
final class PasteboardMonitor {
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int

    /// Вызывается при новом содержимом. Второй аргумент — bundle ID
    /// приложения, которое было активным в момент копирования.
    var onChange: ((NSPasteboard, String?) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start(interval: TimeInterval = 0.35) {
        stop()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Log.clipboard.info("монитор буфера запущен, интервал \(interval, format: .fixed(precision: 2)) с")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Синхронизирует счётчик без обработки — нужно после собственной записи
    /// в буфер, чтобы не разбирать то, что мы сами только что положили.
    func acknowledgeOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    @MainActor
    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onChange?(pasteboard, sourceBundleID)
    }

    deinit { timer?.invalidate() }
}
