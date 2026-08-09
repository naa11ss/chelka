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
        items = [accessibility, automation, screenshots, storage]
    }

    // MARK: - Отдельные разрешения

    private var accessibility: Item {
        Item(
            id: "accessibility",
            title: T("permission.accessibility", "Универсальный доступ"),
            explanation: T("permission.accessibility.why", "Нужен только для медиа-клавиш: ими управляются браузер и плееры, кроме Music и Spotify."),
            cost: T("permission.accessibility.cost", "Без него кнопки работают только с Music и Spotify."),
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
        MediaKeys.requestAuthorization()
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
