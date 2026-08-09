import Foundation

/// Перевод строки интерфейса.
///
/// Русский текст лежит прямо в вызове и работает как запасной вариант:
/// если перевода нет, пользователь увидит осмысленную строку, а не ключ.
/// Английские переводы — в `en.lproj/Localizable.strings` внутри приложения.
///
/// Ядро слинковано статически, поэтому `Bundle.main` находит переводы
/// и для него тоже — отдельный ресурсный бандл не нужен.
public func T(_ key: String, _ russian: String) -> String {
    NSLocalizedString(key, bundle: .main, value: russian, comment: "")
}
