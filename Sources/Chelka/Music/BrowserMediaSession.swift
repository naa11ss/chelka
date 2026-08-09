import AppKit
import ChelkaCore

/// Метаданные того, что играет в браузере, из `navigator.mediaSession`.
///
/// Это тот же источник, из которого браузер рисует своё «сейчас играет»:
/// YouTube, SoundCloud, Яндекс.Музыка и остальные сами кладут туда название,
/// исполнителя и обложку. Ничего надёжнее для веба нет — адрес страницы
/// при воспроизведении внутри ленты вообще не меняется.
///
/// Требует одной ручной галочки в браузере: Safari → Разработка →
/// «Разрешить JavaScript из Apple Events». Без неё модуль молча уступает
/// дорогу разбору страницы по адресу.
enum BrowserMediaSession {

    struct Metadata: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artworkURL: URL?
    }

    /// Скрипт возвращает JSON или пустую строку. Ошибки внутри страницы
    /// гасим на месте: сломанный сайт не должен ронять опрос.
    private static let javaScript = """
    (function(){try{var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    if(!m||!m.title)return '';var a=(m.artwork||[]).map(function(x){return x.src;});\
    return JSON.stringify({title:m.title,artist:m.artist||'',album:m.album||'',artwork:a});}catch(e){return '';}})()
    """

    private static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application "Safari"
                do JavaScript "\(escaped)" in current tab of front window
            end tell
            """
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
             "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera":
            let appName = chromiumName(for: bundleID)
            return """
            tell application "\(appName)"
                execute active tab of front window javascript "\(escaped)"
            end tell
            """
        default:
            return nil
        }
    }

    private static func chromiumName(for bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome": return "Google Chrome"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.brave.Browser": return "Brave Browser"
        case "ru.yandex.desktop.yandex-browser": return "Yandex"
        case "com.operasoftware.Opera": return "Opera"
        default: return "Google Chrome"
        }
    }

    /// Кавычки и переносы внутри AppleScript-строки нужно экранировать.
    private static var escaped: String {
        javaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Браузеры, где выполнение скриптов запрещено, и время следующей попытки.
    private static let backoffLock = NSLock()
    nonisolated(unsafe) private static var backoffUntil: [String: Date] = [:]
    private static let backoffInterval: TimeInterval = 300

    /// Что мы уже успели узнать про доступ к скриптам браузера.
    enum Availability: Equatable {
        case unknown
        case allowed
        case blocked
    }

    nonisolated(unsafe) private static var availability: [String: Availability] = [:]

    static func availability(for bundleID: String) -> Availability {
        backoffLock.lock()
        defer { backoffLock.unlock() }
        return availability[bundleID] ?? .unknown
    }

    /// Известен ли хоть один браузер, где чтение метаданных запрещено.
    static var isBlockedSomewhere: Bool {
        backoffLock.lock()
        defer { backoffLock.unlock() }
        return availability.values.contains(.blocked)
    }

    static func read(bundleID: String) -> Metadata? {
        guard let script = script(for: bundleID) else { return nil }
        guard AppleScriptBridge.isRunning(bundleID: bundleID) else { return nil }

        backoffLock.lock()
        let blockedUntil = backoffUntil[bundleID]
        backoffLock.unlock()
        if let blockedUntil, blockedUntil > Date() { return nil }

        switch AppleScriptBridge.run(script, timeout: 2) {
        case .success(let output) where !output.isEmpty:
            backoffLock.lock()
            availability[bundleID] = .allowed
            backoffLock.unlock()
            return parse(output)

        case .success:
            // Скрипты разрешены, но на странице ничего не играет.
            backoffLock.lock()
            availability[bundleID] = .allowed
            backoffLock.unlock()
            return nil

        case .failure(let failure):
            backoffLock.lock()
            backoffUntil[bundleID] = Date().addingTimeInterval(backoffInterval)
            availability[bundleID] = .blocked
            backoffLock.unlock()
            Log.media.info(
                "чтение mediaSession в \(bundleID, privacy: .public) недоступно (\(String(describing: failure), privacy: .public)), пауза \(Int(backoffInterval)) с"
            )
            return nil
        }
    }

    static func parse(_ json: String) -> Metadata? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              !title.isEmpty
        else { return nil }

        let artist = (object["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let album = (object["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Берём последнюю обложку: сайты перечисляют их от мелкой к крупной.
        let artwork = (object["artwork"] as? [String])?
            .compactMap(URL.init(string:))
            .last

        return Metadata(title: title, artist: artist, album: album, artworkURL: artwork)
    }
}
