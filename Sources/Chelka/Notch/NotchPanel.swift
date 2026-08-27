import AppKit

/// Окно виджета.
///
/// Требования, из-за которых обычный `NSWindow` не подходит:
/// * рисуется поверх меню-бара и поверх полноэкранных приложений;
/// * не забирает фокус у активного приложения при показе;
/// * присутствует на всех рабочих столах и не переключает Spaces.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Уровень выше меню-бара, но ниже системных алертов и скринсейвера.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        // Перехват включается только когда курсор над телом виджета —
        // иначе окно поверх всех остальных съедало бы клики в верхней
        // части экрана, ничего при этом не показывая.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true

        collectionBehavior = [
            .canJoinAllSpaces,      // виден на любом рабочем столе
            .fullScreenAuxiliary,   // виден поверх полноэкранных приложений
            .stationary,            // не уезжает при переключении Spaces
            .ignoresCycle,          // не участвует в Cmd+`
        ]

        // Панель не попадает в скриншоты Cmd+Shift+4 как отдельное окно
        // и не мешает записи экрана.
        isExcludedFromWindowsMenu = true
    }

    /// Нужно для будущей клавиатурной навигации по истории буфера:
    /// без этого borderless-панель не принимает нажатия клавиш.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Без этой переопределённой версии `setFrame` молча ужимает окно
    /// до `visibleFrame` экрана — то есть до области НИЖЕ меню-бара.
    /// Найдено измерением: `CGWindowListCopyWindowInfo` показывал верх
    /// окна на ~39pt ниже настоящего верха экрана, хотя `panel.setFrame`
    /// вызывался с координатами, начинающимися ровно от него. AppKit
    /// по умолчанию считает, что окно не должно перекрывать меню-бар,
    /// и подгоняет любой запрошенный фрейм под это правило — панель
    /// специально рисуется поверх меню-бара и выреза, так что правило
    /// для нас вредно, а не защищает от чего-то.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
