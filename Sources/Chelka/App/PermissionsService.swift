import AppKit
import ApplicationServices
import Combine
import ChelkaCore

/// Состояние разрешений, от которых зависят части виджета.
///
/// Смысл не в том, чтобы выпрашивать всё сразу при первом запуске, а в том,
/// чтобы пользователь понимал, почему что-то не работает, и мог это починить
/// одним нажатием.
@MainActor
final class PermissionsService: ObservableObject {

    enum State: Equatable {
        case granted
        case denied
        /// Проверить нельзя, пока не понадобится: например, управление Music
        /// проверяется только при запущенном Music.
        case unknown
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let explanation: String
        /// Что перестаёт работать без этого разрешения.
        let cost: String
        let state: State
        let settingsURL: URL?
    }

    @Published private(set) var items: [Item] = []

    private let clipboard: ClipboardService
    private let music: MusicService

    init(clipboard: ClipboardService, music: MusicService) {
        self.clipboard = clipboard
        self.music = music
        refresh()
    }

    func refresh() {
        items = [accessibility, automation, browserMetadata, screenshots, storage]
    }

    // MARK: - Отдельные разрешения

    private var accessibility: Item {
        Item(
            id: "accessibility",
            title: T("permission.accessibility", "Универсальный доступ"),
            explanation: T("permission.accessibility.why", "Нужен только для медиа-клавиш: ими управляются браузер и плееры, кроме Music и Spotify."),
            cost: MediaKeys.looksLikeStaleGrant
                ? T(
                    "permission.accessibility.stale",
                    "Разрешение выдано, но система его не признаёт: запись осталась от прошлой сборки. Убери Chelka.app из списка кнопкой «−» и разреши заново."
                  )
                : T("permission.accessibility.cost", "Без него кнопки работают только с Music и Spotify."),
            state: MediaKeys.isAuthorized ? .granted : .denied,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        )
    }

    private var automation: Item {
        let state: State
        switch music.status {
        case .automationDenied: state = .denied
        case .connected: state = .granted
        default: state = .unknown
        }

        return Item(
            id: "automation",
            title: T("permission.automation", "Управление Music и Spotify"),
            explanation: T("permission.automation.why", "Через него виджет получает название трека, обложку и позицию воспроизведения."),
            cost: T("permission.automation.cost", "Без него останутся только кнопки без названия трека."),
            state: state,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        )
    }

    /// Чтение `navigator.mediaSession` в браузере: даёт название трека
    /// и обложку там, где адрес страницы ничего не говорит — например,
    /// при воспроизведении внутри ленты.
    private var browserMetadata: Item {
        let state: State
        switch BrowserMediaSession.availability(for: "com.apple.Safari") {
        case .allowed: state = .granted
        case .blocked: state = .denied
        case .unknown: state = .unknown
        }

        return Item(
            id: "browser-metadata",
            title: T("permission.browserJS", "Метаданные из браузера"),
            explanation: T(
                "permission.browserJS.why",
                "Название трека и обложку браузер отдаёт только скриптом. Включается один раз: Safari → Настройки → Дополнения → «Показывать функции для веб-разработчиков», затем Разработка → «Разрешить JavaScript из Apple Events»."
            ),
            cost: T(
                "permission.browserJS.cost",
                "Без этого вместо трека показывается заголовок вкладки, а обложка находится только у страниц, где ролик и есть страница."
            ),
            state: state,
            settingsURL: nil
        )
    }

    private var screenshots: Item {
        let directory = ScreenshotWatcher.systemScreenshotDirectory
        let readable = FileManager.default.isReadableFile(atPath: directory.path)

        return Item(
            id: "screenshots",
            title: T("permission.screenshots", "Доступ к папке снимков"),
            explanation: String(format: T("permission.screenshots.why", "Снимки экрана попадают в файл, а не в буфер. Виджет следит за папкой %@."), directory.lastPathComponent),
            cost: T("permission.screenshots.cost", "Без него снимки через ⇧⌘4 в историю не попадут."),
            state: readable ? .granted : .denied,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Files")
        )
    }

    private var storage: Item {
        let state: State
        switch clipboard.persistence {
        case .onDisk: state = .granted
        case .memoryOnly: state = .denied
        }

        return Item(
            id: "keychain",
            title: T("permission.keychain", "Ключ шифрования в связке ключей"),
            explanation: T("permission.keychain.why", "История буфера шифруется, ключ хранится в связке ключей."),
            cost: T("permission.keychain.cost", "Без него история живёт только до выхода из приложения."),
            state: state,
            settingsURL: nil
        )
    }

    // MARK: - Действия

    func requestAccessibility() {
        MediaKeys.requestAuthorizationOnce()
    }

    /// Разрешение выдано, но не действует — обычно из-за того, что подпись
    /// приложения сменилась и в списке осталась запись от прошлой сборки.
    var hasStaleAccessibilityGrant: Bool {
        MediaKeys.looksLikeStaleGrant
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
