import CryptoKit
import Foundation
import Security

/// Шифрование истории буфера.
///
/// История лежит на диске между запусками, а в буфер попадает всё подряд —
/// от ссылок до содержимого менеджера паролей. Поэтому на диск ничего
/// не пишется открытым текстом, включая превью и ключи дедупликации.
public struct ClipboardCrypto: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Шифрует данные. Возвращает combined-представление AES-GCM
    /// (nonce + шифротекст + тег) — самодостаточное для хранения.
    public func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw ChelkaError.crypto("не удалось собрать зашифрованный блок")
        }
        return combined
    }

    public func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    /// Ключ дедупликации: HMAC содержимого на том же секрете.
    ///
    /// Обычный хэш выдал бы содержимое подбором — по SHA256 короткого текста
    /// вроде пароля или адреса он восстанавливается словарём. HMAC без ключа
    /// не проверить.
    public func contentKey(for data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Ошибки ядра.
public enum ChelkaError: Error, CustomStringConvertible {
    case crypto(String)
    case keychain(String, OSStatus)
    case storage(String)

    public var description: String {
        switch self {
        case .crypto(let message): return "шифрование: \(message)"
        case .keychain(let message, let status): return "keychain: \(message) (OSStatus \(status))"
        case .storage(let message): return "хранилище: \(message)"
        }
    }
}

/// Ключ шифрования истории в Keychain.
///
/// Не в файле рядом с базой: файл читается любым процессом пользователя,
/// а связка ключей ограничивает доступ подписью приложения.
public enum ClipboardKeychain {
    public static let service = "com.ivan.chelka"
    public static let account = "clipboard-history-key"

    public static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        try store(key)
        return key
    }

    static func loadKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ChelkaError.keychain("ключ найден, но не читается", status)
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw ChelkaError.keychain("чтение ключа не удалось", status)
        }
    }

    static func store(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Ключ нужен фоновому монитору буфера сразу после перезагрузки,
            // но за пределы этого устройства уезжать не должен.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ChelkaError.keychain("сохранение ключа не удалось", status)
        }
    }

    /// Удаляет ключ — история после этого нечитаема. Нужно для «стереть всё».
    public static func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChelkaError.keychain("удаление ключа не удалось", status)
        }
    }
}
