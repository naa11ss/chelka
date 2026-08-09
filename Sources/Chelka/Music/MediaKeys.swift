import AppKit
import ApplicationServices
import ChelkaCore

/// Глобальные медиа-клавиши.
///
/// Запасной путь для всего, что не Music и не Spotify: браузер, Яндекс.Музыка,
/// VLC. Управление работает, но название трека и обложку так не получить —
/// системный Now Playing сторонним приложениям с macOS 15.4 закрыт.
///
/// Требует разрешения «Универсальный доступ»: синтетические события ввода
/// без него система отбрасывает молча.
enum MediaKeys {

    private enum Key: Int32 {
        case playPause = 16
        case next = 17
        case previous = 18
    }

    /// Выдано ли разрешение на отправку событий ввода.
    ///
    /// Проверка без запроса: `AXIsProcessTrustedWithOptions` с включённым
    /// запросом показывает диалог при каждом вызове, а спрашивать состояние
    /// приходится часто.
    static var isAuthorized: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Показывает системный диалог с просьбой выдать разрешение.
    ///
    /// Не чаще одного раза за запуск. Повторные диалоги на каждое нажатие
    /// кнопки — самый быстрый способ довести пользователя до удаления
    /// приложения, а разрешение от повторов всё равно не появится.
    @discardableResult
    static func requestAuthorizationOnce() -> Bool {
        guard !isAuthorized else { return true }
        guard !hasPrompted else { return false }
        hasPrompted = true

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        Log.media.info("запрошен «Универсальный доступ» — диалог за этот запуск больше не показываем")
        return false
    }

    /// Показывали ли диалог в этом запуске.
    nonisolated(unsafe) private static var hasPrompted = false

    /// Разрешение выдано, но система всё ещё считает приложение недоверенным.
    ///
    /// Так бывает после пересборки: ad-hoc подпись меняется, и запись
    /// в списке разрешений остаётся от прошлой личности приложения.
    /// Пользователю нужно убрать старую запись и добавить новую.
    static var looksLikeStaleGrant: Bool {
        hasPrompted && !isAuthorized
    }

    @discardableResult
    static func playPause() -> Bool { send(.playPause) }

    @discardableResult
    static func next() -> Bool { send(.next) }

    @discardableResult
    static func previous() -> Bool { send(.previous) }

    private static func send(_ key: Key) -> Bool {
        guard isAuthorized else {
            Log.media.info("медиа-клавиши недоступны: нет разрешения «Универсальный доступ»")
            return false
        }

        post(key, isDown: true)
        post(key, isDown: false)
        return true
    }

    /// Медиа-клавиши приходят системе не как обычные нажатия, а как
    /// системное событие с подтипом 8; код клавиши и фаза упакованы в data1.
    private static func post(_ key: Key, isDown: Bool) {
        let phase = isDown ? 0x0A00 : 0x0B00
        let data1 = Int((key.rawValue << 16) | Int32(phase))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(phase)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
