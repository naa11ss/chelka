import AppKit
import ChelkaCore

/// Разговор с конкретным плеером на его языке.
///
/// Music.app и Spotify описывают одно и то же по-разному: у Spotify
/// длительность в миллисекундах и есть ссылка на обложку, у Music —
/// секунды и обложка только байтами. Разница спрятана здесь.
struct MusicSourceClient {
    let source: MusicSource

    var isRunning: Bool {
        AppleScriptBridge.isRunning(bundleID: source.bundleID)
    }

    // MARK: - Состояние

    /// Опрашивает плеер. `nil` — плеер закрыт, остановлен или не ответил.
    func query() -> Result<NowPlaying?, AppleScriptBridge.Failure> {
        guard isRunning else { return .success(nil) }

        switch AppleScriptBridge.run(stateScript) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let text):
            guard text != "stopped", !text.isEmpty else { return .success(nil) }
            return .success(parse(text))
        }
    }

    private var stateScript: String {
        switch source {
        case .appleMusic:
            return """
            tell application "Music"
                if player state is stopped then return "stopped"
                set t to current track
                set out to (player state as text) & linefeed
                set out to out & (database ID of t as text) & linefeed
                set out to out & (name of t) & linefeed
                set out to out & (artist of t) & linefeed
                set out to out & (album of t) & linefeed
                set out to out & ((duration of t) as text) & linefeed
                set out to out & ((player position) as text)
                return out
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                set out to (player state as text) & linefeed
                set out to out & (id of t as text) & linefeed
                set out to out & (name of t) & linefeed
                set out to out & (artist of t) & linefeed
                set out to out & (album of t) & linefeed
                set out to out & (((duration of t) / 1000) as text) & linefeed
                set out to out & ((player position) as text)
                return out
            end tell
            """
        }
    }

    private func parse(_ text: String) -> NowPlaying? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 7 else {
            Log.media.error("непонятный ответ плеера: \(lines.count) строк")
            return nil
        }

        // AppleScript отдаёт дробные числа в локали системы —
        // на русской раскладке это запятая, и Double(«3,5») вернёт nil.
        func number(_ raw: String) -> Double {
            Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
        }

        return NowPlaying(
            source: source,
            trackID: lines[1].trimmingCharacters(in: .whitespaces),
            title: lines[2],
            artist: lines[3],
            album: lines[4],
            isPlaying: lines[0].trimmingCharacters(in: .whitespaces).lowercased() == "playing",
            duration: number(lines[5]),
            position: number(lines[6]),
            sampledAt: MonotonicClock.now
        )
    }

    // MARK: - Управление

    enum Command {
        case playPause
        case next
        case previous

        fileprivate var appleScriptVerb: String {
            switch self {
            case .playPause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            }
        }
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        guard isRunning else { return false }

        let appName = source == .appleMusic ? "Music" : "Spotify"
        let script = "tell application \"\(appName)\" to \(command.appleScriptVerb)"

        if case .success = AppleScriptBridge.run(script, timeout: 1.5) {
            return true
        }
        return false
    }

    // MARK: - Обложка

    /// Обложка текущего трека.
    ///
    /// У Spotify есть ссылка — качаем. У Music обложка доступна только
    /// байтами через скрипт, поэтому просим записать её во временный файл:
    /// вытаскивать двоичные данные через стандартный вывод osascript
    /// заметно менее надёжно.
    func artwork() -> Data? {
        guard isRunning else { return nil }

        switch source {
        case .spotify:
            guard case .success(let urlString) = AppleScriptBridge.run(
                "tell application \"Spotify\" to return artwork url of current track"
            ), let url = URL(string: urlString) else { return nil }

            return try? Data(contentsOf: url)

        case .appleMusic:
            let path = NSTemporaryDirectory() + "chelka-artwork.bin"
            let script = """
            tell application "Music"
                if (count of artworks of current track) is 0 then return ""
                set d to raw data of artwork 1 of current track
            end tell
            set p to "\(path)"
            try
                set f to open for access (POSIX file p) with write permission
                set eof f to 0
                write d to f
                close access f
            on error
                try
                    close access (POSIX file p)
                end try
                return ""
            end try
            return p
            """

            guard case .success(let result) = AppleScriptBridge.run(script, timeout: 3),
                  !result.isEmpty
            else { return nil }

            defer { try? FileManager.default.removeItem(atPath: path) }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }
}
