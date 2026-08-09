import AppKit
import CoreAudio
import ChelkaCore

/// Приложение, которое прямо сейчас выводит звук.
struct AudioSource: Equatable {
    /// Bundle ID приложения, каким его увидит пользователь.
    let bundleID: String
    let name: String
    /// Что именно звучит, если это удалось узнать — например, вкладка браузера.
    var detail: String?

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Кто сейчас играет — для всего, что не Music и не Spotify.
///
/// Системный Now Playing с macOS 15.4 закрыт: приватный `MediaRemote`
/// на 26.5 проверен и не отдаёт данных даже при играющем звуке. Зато
/// CoreAudio публично сообщает, какие процессы выводят звук — этого хватает,
/// чтобы показать приложение и управлять им медиа-клавишами.
enum AudioSourceMonitor {

    /// Звук выводят вспомогательные процессы, а не сами приложения:
    /// у Safari это com.apple.WebKit.GPU, у Chrome — отдельный helper.
    /// Родитель у них launchd, поэтому по дереву процессов хозяина не найти.
    private static let helperHosts: [(prefix: String, hosts: [String])] = [
        ("com.apple.WebKit", ["com.apple.Safari"]),
        ("com.google.Chrome.helper", ["com.google.Chrome"]),
        ("com.microsoft.edgemac.helper", ["com.microsoft.edgemac"]),
        ("com.brave.Browser.helper", ["com.brave.Browser"]),
        ("ru.yandex.desktop.yandex-browser.helper", ["ru.yandex.desktop.yandex-browser"]),
        ("company.thebrowser.browser.helper", ["company.thebrowser.Browser"]),
        ("com.operasoftware.Opera.helper", ["com.operasoftware.Opera"]),
    ]

    /// Приложения, чей звук показывать не нужно: системные службы,
    /// звук уведомлений и прочий фон.
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.PowerChime",
        "com.apple.controlcenter",
        "com.apple.audiomxd",
        "com.apple.mediaremoted",
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.ivan.chelka",
    ]

    /// Кто сейчас выводит звук.
    static func currentSources() -> [AudioSource] {
        var seen = Set<String>()
        var sources: [AudioSource] = []

        for object in processObjects() {
            guard flag(object, kAudioProcessPropertyIsRunningOutput) == true else { continue }
            guard let rawBundleID = string(object, kAudioProcessPropertyBundleID), !rawBundleID.isEmpty else { continue }

            guard let resolved = resolveHost(for: rawBundleID) else { continue }
            guard !ignoredBundleIDs.contains(resolved), !seen.contains(resolved) else { continue }

            seen.insert(resolved)
            sources.append(
                AudioSource(
                    bundleID: resolved,
                    name: applicationName(for: resolved),
                    detail: nil
                )
            )
        }

        return sources
    }

    /// Приводит вспомогательный процесс к приложению, знакомому пользователю.
    ///
    /// Порядок важен: сначала таблица подмен, потом собственный идентификатор.
    /// XPC-службы вроде com.apple.WebKit.GPU числятся «запущенными
    /// приложениями» наравне с обычными, поэтому проверка «запущено ли»
    /// сама по себе вспомогательный процесс не отсеивает.
    private static func resolveHost(for bundleID: String) -> String? {
        for entry in helperHosts where bundleID.hasPrefix(entry.prefix) {
            if let running = entry.hosts.first(where: isUserFacingApplication) {
                return running
            }
        }

        // Общее правило для Chromium-подобных: «…helper (Renderer)» → «…».
        if let range = bundleID.range(of: ".helper") {
            let candidate = String(bundleID[bundleID.startIndex..<range.lowerBound])
            if isUserFacingApplication(candidate) { return candidate }
        }

        if isUserFacingApplication(bundleID) { return bundleID }

        // Осталась служба без опознанного хозяина — показывать её незачем.
        return nil
    }

    /// Приложение, которое пользователь видит в Dock и переключателе окон.
    /// У XPC-служб и фоновых помощников политика активации другая.
    private static func isUserFacingApplication(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.activationPolicy == .regular }
    }

    private static func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        // displayName оставляет «.app» для приложений вне обычных папок —
        // например, для Safari, который лежит в системном криптексе.
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - CoreAudio

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }

        return value.takeRetainedValue() as String
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}

/// Название того, что звучит в браузере.
///
/// Какая именно вкладка играет, система не сообщает, поэтому берём заголовок
/// активной вкладки: в подавляющем большинстве случаев человек слушает
/// то, что смотрит. Требует разрешения на управление браузером; отказ
/// проходит молча — виджет просто покажет имя приложения.
enum BrowserTabTitle {

    private static let scripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return name of current tab of front window",
        "com.google.Chrome": "tell application \"Google Chrome\" to return title of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return title of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return title of active tab of front window",
        "ru.yandex.desktop.yandex-browser": "tell application \"Yandex\" to return title of active tab of front window",
        "com.operasoftware.Opera": "tell application \"Opera\" to return title of active tab of front window",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        scripts[bundleID] != nil
    }

    /// Отказавшие браузеры и время, до которого их не трогаем.
    ///
    /// Без этого запрещённый доступ означал бы запуск osascript каждые
    /// две секунды впустую: разрешение от повторов не появится, а процесс
    /// и задержка вполне настоящие.
    private static let backoffLock = NSLock()
    nonisolated(unsafe) private static var backoffUntil: [String: Date] = [:]
    private static let backoffInterval: TimeInterval = 120

    static func title(for bundleID: String) -> String? {
        guard let script = scripts[bundleID] else { return nil }
        guard AppleScriptBridge.isRunning(bundleID: bundleID) else { return nil }

        backoffLock.lock()
        let blockedUntil = backoffUntil[bundleID]
        backoffLock.unlock()

        if let blockedUntil, blockedUntil > Date() { return nil }

        switch AppleScriptBridge.run(script, timeout: 1.5) {
        case .success(let title) where !title.isEmpty:
            return clean(title)

        case .failure(let failure):
            if failure == .automationDenied || failure == .timedOut {
                backoffLock.lock()
                backoffUntil[bundleID] = Date().addingTimeInterval(backoffInterval)
                backoffLock.unlock()
                Log.media.info("заголовок вкладки \(bundleID, privacy: .public) недоступен, пауза \(Int(backoffInterval)) с")
            }
            return nil

        case .success:
            return nil
        }
    }

    /// Браузеры дописывают к заголовку своё имя и служебные хвосты.
    private static func clean(_ title: String) -> String {
        var result = title
        for suffix in [" - YouTube", " — YouTube", " - Google Chrome", " — Яндекс Браузер"] {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
