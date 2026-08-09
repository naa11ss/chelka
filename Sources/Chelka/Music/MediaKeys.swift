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
    static var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    /// Показывает системный диалог с просьбой выдать разрешение.
    /// Вызывать только по явному действию пользователя.
    static func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
