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
    /// гасим на месте: сломанный сайт не должен ронять опрос. `playing` —
    /// потому что "текущая" вкладка браузера (активная/видимая) и та,
    /// что реально звучит, — разные вещи: можно слушать SoundCloud в
    /// фоновой вкладке, читая статью в активной. Без этого признака
    /// нечем отличить одну от другой при переборе всех вкладок разом.
    private static let javaScript = """
    (function(){try{var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    if(!m||!m.title)return '';var a=(m.artwork||[]).map(function(x){return x.src;});\
    var p=navigator.mediaSession.playbackState==='playing';\
    return JSON.stringify({title:m.title,artist:m.artist||'',album:m.album||'',artwork:a,playing:p});}catch(e){return '';}})()
    """

    /// Разделитель между результатами разных вкладок — ASCII 30 (Record
    /// Separator), не пересекается с ASCII 31, которым уже размечены поля
    /// внутри одной записи в `MusicSourceClient`.
    private static let tabResultSeparator = "\u{1E}"

    /// Перебирает КАЖДУЮ вкладку каждого окна, а не только активную:
    /// CoreAudio (`AudioSourceMonitor`) находит, что звук выводит браузер
    /// как процесс, но не какая именно вкладка внутри него — раньше здесь
    /// бралась `current tab of front window`, и если пользователь смотрел
    /// одну вкладку, а звук шёл из другой (фоновой), карточка показывала
    /// название и обложку не того, что реально играет.
    private static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application "Safari"
                set outputList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set r to (do JavaScript "\(escaped)" in t)
                        on error
                            set r to ""
                        end try
                        if r is not "" then set end of outputList to r
                    end repeat
                end repeat
                set AppleScript's text item delimiters to (character id 30)
                set outputStr to outputList as text
                set AppleScript's text item delimiters to ""
                return outputStr
            end tell
            """
        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
             "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera":
            let appName = chromiumName(for: bundleID)
            return """
            tell application "\(appName)"
                set outputList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set r to (execute t javascript "\(escaped)")
                        on error
                            set r to ""
                        end try
                        if r is not "" then set end of outputList to r
                    end repeat
                end repeat
                set AppleScript's text item delimiters to (character id 30)
                set outputStr to outputList as text
                set AppleScript's text item delimiters to ""
                return outputStr
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
            return parse(multiTabOutput: output)

        case .success:
            // Скрипты разрешены, но на странице ничего не играет.
            backoffLock.lock()
            availability[bundleID] = .allowed
            backoffLock.unlock()
            return nil

        case .failure(let failure):
            // Только `.automationDenied`/`.timedOut` — это действительно
            // «доступ запрещён», и стоит подождать 5 минут, а заодно
            // пометить `.blocked` (это то, что показывает подсказку
            // «включите JavaScript из Apple Events» в разрешениях). Прочие
            // отказы (`.scriptError` — например, у браузера сейчас нет ни
            // одного окна, `.appNotRunning`) не про разрешения и не должны
            // ни блокировать источник на пять минут, ни зажигать эту
            // подсказку — тот же принцип, что уже применён в `BrowserTabTitle`.
            if failure == .automationDenied || failure == .timedOut {
                backoffLock.lock()
                backoffUntil[bundleID] = Date().addingTimeInterval(backoffInterval)
                availability[bundleID] = .blocked
                backoffLock.unlock()
            }
            Log.media.info(
                "чтение mediaSession в \(bundleID, privacy: .public) недоступно (\(String(describing: failure), privacy: .public))"
            )
            return nil
        }
    }

    /// Результат по одной вкладке, с признаком "реально звучит сейчас" —
    /// сайты, честно выставляющие `playbackState`, встречаются не всегда,
    /// поэтому это предпочтение, а не жёсткий фильтр.
    private struct TabResult {
        let metadata: Metadata
        let playing: Bool
    }

    /// Разбирает результаты со всех вкладок разом и выбирает ту, что реально
    /// играет. Ни одна не отметилась как `playing` (сайт не поддерживает
    /// `playbackState`) — берём первую с осмысленными метаданными, как
    /// раньше при одной-единственной активной вкладке.
    static func parse(multiTabOutput output: String) -> Metadata? {
        let results = output
            .components(separatedBy: Self.tabResultSeparator)
            .compactMap(parseOneTab)
        return results.first { $0.playing }?.metadata ?? results.first?.metadata
    }

    private static func parseOneTab(_ json: String) -> TabResult? {
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
        let playing = object["playing"] as? Bool ?? false

        return TabResult(
            metadata: Metadata(title: title, artist: artist, album: album, artworkURL: artwork),
            playing: playing
        )
    }
}
