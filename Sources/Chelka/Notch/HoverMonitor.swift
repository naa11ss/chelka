import AppKit
import ChelkaCore

/// Следит за положением курсора глобально.
///
/// Почему мониторы событий, а не `NSTrackingArea`: панель не активна и
/// перекрыта чужими окнами, tracking area в таких условиях теряет
/// mouseExited и виджет залипает раскрытым.
///
/// Мониторы мыши не требуют разрешения «Универсальный доступ» —
/// оно нужно только для перехвата клавиатуры.
final class HoverMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
    ]

    /// Вызывается при каждом движении курсора. Точка — глобальные координаты.
    var onMove: ((NSPoint) -> Void)?

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] _ in
            self?.onMove?(NSEvent.mouseLocation)
        }
        // Локальный монитор — для движений над собственной панелью:
        // глобальный их не видит.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            self?.onMove?(NSEvent.mouseLocation)
            return event
        }

        Log.notch.debug("монитор курсора запущен")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit { stop() }
}
