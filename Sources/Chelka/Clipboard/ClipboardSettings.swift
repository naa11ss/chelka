import AppKit
import Combine
import ChelkaCore

/// Настройки захвата буфера.
///
/// По умолчанию сохраняется всё, что копируется. Чёрный список приложений —
/// точечный инструмент: добавил менеджер паролей или банковское приложение,
/// и его содержимое в историю не попадает.
final class ClipboardSettings: ObservableObject {
    private enum Keys {
        static let blacklist = "chelka.clipboard.blacklist"
        static let skipConcealed = "chelka.clipboard.skipConcealed"
        static let captureScreenshots = "chelka.clipboard.captureScreenshots"
    }

    private let defaults: UserDefaults

    /// Bundle ID приложений, из которых не сохраняем.
    @Published var blacklist: Set<String> {
        didSet { defaults.set(Array(blacklist), forKey: Keys.blacklist) }
    }

    /// Пропускать содержимое, помеченное менеджерами паролей как секретное.
    /// Выключено по умолчанию — сохраняем всё, как договаривались.
    @Published var skipConcealed: Bool {
        didSet { defaults.set(skipConcealed, forKey: Keys.skipConcealed) }
    }

    /// Подхватывать файлы снимков экрана из папки скриншотов.
    @Published var captureScreenshots: Bool {
        didSet { defaults.set(captureScreenshots, forKey: Keys.captureScreenshots) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.blacklist = Set(defaults.stringArray(forKey: Keys.blacklist) ?? [])
        self.skipConcealed = defaults.bool(forKey: Keys.skipConcealed)
        self.captureScreenshots = defaults.object(forKey: Keys.captureScreenshots) as? Bool ?? true
    }

    func isBlacklisted(_ bundleID: String) -> Bool {
        blacklist.contains(bundleID)
    }

    func addToBlacklist(_ bundleID: String) {
        blacklist.insert(bundleID)
        Log.clipboard.info("в чёрный список добавлено \(bundleID, privacy: .public)")
    }

    func removeFromBlacklist(_ bundleID: String) {
        blacklist.remove(bundleID)
    }
}
