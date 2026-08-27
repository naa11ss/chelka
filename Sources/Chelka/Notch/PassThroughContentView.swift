import AppKit
import ChelkaCore
import UniformTypeIdentifiers

/// Корневой вид панели, пропускающий клики сквозь себя.
///
/// Панель заведомо больше видимого виджета — иначе анимации некуда расти.
/// Без этого класса прозрачные поля панели воровали бы клики у приложений
/// под ними: пользователь целится в меню-бар, а попадает в невидимое окно.
final class PassThroughContentView: NSView {

    /// Прямоугольник, внутри которого вид реально принимает события.
    /// Координаты — этого вида (AppKit, начало внизу слева).
    var interactiveRect: CGRect = .zero {
        didSet {
            guard interactiveRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Файлы, отпущенные над виджетом. Приём живёт здесь, на уровне AppKit,
    /// а не в SwiftUI: `.onDrop` внутри `NSHostingView` в borderless
    /// `nonactivatingPanel` до вида не доходил — перетаскивание из Finder
    /// проверенно не долетало, хотя виджет при этом раскрывался.
    /// Регистрация вида приёмником перетаскивания — путь, на котором
    /// не зависишь ни от того, ключевое ли окно, ни от того, как SwiftUI
    /// пробрасывает drop внутрь хостинга.
    var onFileDrop: (([URL]) -> Void)?
    /// Сообщает, что файл занесён над виджетом (или уведён) — по этому
    /// признаку карточка переключается на вкладку «Файлы» и подсвечивается.
    var onDragTargetingChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Для contentView система передаёт точку в координатах окна.
        let local = convert(point, from: nil)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Приём файлов

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender) else { return [] }
        Log.clipboard.info("перетаскивание вошло в панель")
        onDragTargetingChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetingChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasFileURLs(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTargetingChange?(false)

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty
        else {
            Log.clipboard.error("перетаскивание без файловых адресов")
            return false
        }

        Log.clipboard.info("принято файлов: \(urls.count)")
        onFileDrop?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDragTargetingChange?(false)
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }
}
