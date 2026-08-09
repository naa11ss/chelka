import AppKit
import Carbon.HIToolbox
import ChelkaCore

/// Глобальные горячие клавиши через Carbon.
///
/// Почему Carbon, а не перехват событий: `RegisterEventHotKey` не требует
/// разрешения «Универсальный доступ», а глобальный монитор клавиатуры —
/// требует. Пользователь не должен пускать виджет читать всё, что печатает,
/// ради одного сочетания.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    struct Binding: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Сочетание по умолчанию: ⌥⌘V.
    ///
    /// ⌘⇧V не берём умолчанием: в Chrome, Slack, Telegram и десятке других
    /// приложений это «вставить без форматирования», и перехват сломал бы его
    /// во всей системе.
    static let defaultBinding = Binding(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(optionKey | cmdKey)
    )

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private static let signature: OSType = 0x43_48_4C_4B  // 'CHLK'

    private init() {}

    /// Регистрирует сочетание. Возвращает идентификатор для снятия.
    @discardableResult
    func register(_ binding: Binding, action: @escaping () -> Void) -> UInt32? {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)

        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            Log.app.error("не удалось зарегистрировать сочетание, код \(status)")
            return nil
        }

        refs[id] = hotKeyRef
        handlers[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] {
            UnregisterEventHotKey(ref)
        }
        refs[id] = nil
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in refs.keys { unregister(id) }
    }

    fileprivate func handle(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }
}

/// C-совместимый обработчик: Carbon принимает только указатель на функцию.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        HotkeyCenter.shared.handle(id: id)
    }
    return noErr
}
